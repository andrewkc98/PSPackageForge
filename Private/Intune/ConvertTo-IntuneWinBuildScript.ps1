function ConvertTo-IntuneWinBuildScript {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNull()]
        [object] $PackageInput
    )
    $required = @('ManifestPath', 'SourcePath', 'SetupExecutablePath', 'InstallerPath', 'InstallerFileName', 'SHA256', 'OutputPath', 'IntuneWinPath')
    foreach ($name in $required) {
        if ($null -eq $PackageInput.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace("$($PackageInput.$name)")) {
            throw [System.IO.InvalidDataException]::new("Package input is missing '$name'.")
        }
    }
    $template = @'
[CmdletBinding()]
param(
    [Parameter()]
    [AllowNull()]
    [string] $IntuneWinAppUtilPath
)
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath($PSScriptRoot)
$manifestPath = Join-Path $root 'PackageManifest.json'
$packagePath = Join-Path $root 'Package'
$outputPath = Join-Path $root 'IntuneWin'
function Get-Value($InputObject, [string] $Name) {
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}
function Require-File([string] $Path, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Package is missing required $Description '$Path'." }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Length -le 0) { throw "Package required $Description '$Path' is empty." }
    return $item
}
function Get-RelativePath([string] $Base, [string] $Path) {
    $prefix = $Base.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    return $Path.Substring($prefix.Length).Replace('\','/')
}
function Assert-PackageEvidence {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "PackageManifest.json was not found: '$manifestPath'." }
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { throw "PackageManifest.json is malformed JSON: $($_.Exception.Message)" }
    if ([string](Get-Value $manifest 'SchemaVersion') -ne '__MANIFEST_SCHEMA_VERSION__') { throw "PackageManifest.json schema must be exactly '__MANIFEST_SCHEMA_VERSION__'." }
    if ([string]$manifest.Generator.Name -ne 'PSPackageForge' -or [string]$manifest.Generator.Version -ne '__GENERATOR_VERSION__') { throw 'PackageManifest.json generator metadata is invalid.' }
    $requiredVersion = [string]$manifest.Generator.RequiredPSADTVersion
    if ($requiredVersion -ne '__REQUIRED_PSADT_VERSION__') { throw "PackageManifest.json must require PSADT exactly '__REQUIRED_PSADT_VERSION__'." }
    if ([string](Get-Value $manifest 'Readiness') -ne 'ReviewRequired') { throw "PackageManifest.json readiness must be 'ReviewRequired'." }
    $installer = $manifest.Installer
    $fileName = [string]$installer.FileName
    $pathText = [string]$installer.Path
    $expectedHash = [string]$installer.SHA256
    if ([string]::IsNullOrWhiteSpace($fileName) -or $pathText -cne $fileName -or $fileName.IndexOfAny([char[]]@('\','/')) -ge 0 -or [IO.Path]::IsPathRooted($fileName) -or $fileName -in @('.','..') -or $expectedHash -notmatch '^[0-9A-Fa-f]{64}$') { throw 'PackageManifest.json installer filename or SHA256 is invalid.' }
    $stagedInstaller = Join-Path $root $fileName
    [void](Require-File $stagedInstaller 'staged installer')
    if (-not [string]::Equals((Get-FileHash -LiteralPath $stagedInstaller -Algorithm SHA256).Hash, $expectedHash, [StringComparison]::OrdinalIgnoreCase)) { throw 'Staged installer hash mismatch.' }
    $spec = Get-Value $manifest 'PackageSpec'
    $map = @($spec.ReturnCodeMap)
    if ($map.Count -eq 0) { throw 'PackageManifest.json ReturnCodeMap must be nonempty.' }
    $mapByCode = @{}
    foreach ($row in $map) {
        $rawCode = $row.Code
        try { $number = [decimal]$rawCode; if ($rawCode -is [bool] -or $null -eq $rawCode -or [decimal]::Truncate($number) -ne $number -or $number -lt [int]::MinValue -or $number -gt [int]::MaxValue -or [int]$number -eq [int]::MinValue) { throw 'invalid' } } catch { throw 'PackageManifest.json ReturnCodeMap contains an invalid Code.' }
        $code = [int]$number
        if ($rawCode -is [string]) { throw 'PackageManifest.json ReturnCodeMap contains an invalid Code.' }
        if ($mapByCode.ContainsKey([string]$code)) { throw "PackageManifest.json ReturnCodeMap repeats Code $code." }
        $classification = [string]$row.Classification
        if ($classification -notin @('Failure','Success','SuccessRebootRequired','SuccessRebootInitiated','Retry')) { throw "PackageManifest.json ReturnCodeMap has unsupported Classification '$classification'." }
        $mapByCode[[string]$code] = $classification
    }
    foreach ($operation in @('InstallCommand','UninstallCommand')) {
        $command = Get-Value $spec $operation
        if (($command -isnot [pscustomobject] -and $command -isnot [hashtable]) -or $null -eq $command) { throw "PackageManifest.json $operation command must be a structured object." }
        $executable = Get-Value $command 'Executable'; $workingDirectory = Get-Value $command 'WorkingDirectory'
        if ($executable -isnot [string] -or [string]::IsNullOrWhiteSpace($executable)) { throw "PackageManifest.json does not contain a resolved $operation command." }
        if ($null -ne $workingDirectory -and $workingDirectory -isnot [string]) { throw "PackageManifest.json $operation command WorkingDirectory must be a string or null." }
        $rawArgs = Get-Value $command 'ArgumentList'; $codes = Get-Value $command 'ExpectedExitCodes'
        if ($rawArgs -isnot [array] -or @($rawArgs | Where-Object { $_ -isnot [string] }).Count -gt 0 -or $codes -isnot [array] -or $codes.Count -eq 0) { throw "PackageManifest.json $operation arguments or expected exit codes are invalid." }
        $seenExpected = @{}
        foreach ($code in $codes) {
            try { $numericCode=[decimal]$code; if ($code -is [bool] -or $code -is [string] -or $null -eq $code -or [decimal]::Truncate($numericCode) -ne $numericCode -or $numericCode -lt [int]::MinValue -or $numericCode -gt [int]::MaxValue -or [int]$numericCode -eq [int]::MinValue) { throw 'invalid' } } catch { throw "PackageManifest.json $operation expected exit code is invalid." }
            $expected = [int]$numericCode
            if ($seenExpected.ContainsKey([string]$expected)) { throw "PackageManifest.json $operation repeats expected exit code $expected." }
            $seenExpected[[string]$expected] = $true
            if (-not $mapByCode.ContainsKey([string]$expected) -or $mapByCode[[string]$expected] -notin @('Success','SuccessRebootRequired','SuccessRebootInitiated')) { throw "Expected exit code $expected for $operation must have exactly one success ReturnCodeMap entry." }
        }
    }
    if (-not (Test-Path -LiteralPath $packagePath -PathType Container)) { throw "Package directory was not found: '$packagePath'." }
    $relative = [ordered]@{ Launcher='Invoke-AppDeployToolkit.exe'; Frontend='Invoke-AppDeployToolkit.ps1'; Config='Config/config.psd1'; ToolkitManifest='PSAppDeployToolkit/PSAppDeployToolkit.psd1'; Payload="Files/$fileName" }
    $resolved = @{}
    foreach ($key in $relative.Keys) { $resolved[$key] = (Require-File (Join-Path $packagePath ($relative[$key] -replace '/', [IO.Path]::DirectorySeparatorChar)) $key).FullName }
    $bytes = [IO.File]::ReadAllBytes($resolved.Launcher)
    if ($bytes.Length -lt 68 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'Package launcher is not a valid PE executable.' }
    $offset = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($offset -lt 64 -or $offset -gt ($bytes.Length - 4) -or $bytes[$offset] -ne 0x50 -or $bytes[$offset + 1] -ne 0x45 -or $bytes[$offset + 2] -ne 0 -or $bytes[$offset + 3] -ne 0) { throw 'Package launcher is not a valid PE executable.' }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($resolved.Frontend), [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw 'Package frontend contains PowerShell parse errors.' }
    foreach ($fn in @('Install-ADTDeployment','Uninstall-ADTDeployment')) { if (@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn}, $true)).Count -ne 1) { throw "Package frontend must contain exactly one function '$fn'." } }
    try { $toolkitManifest = Import-PowerShellDataFile -LiteralPath $resolved.ToolkitManifest -ErrorAction Stop } catch { throw "Bundled toolkit manifest could not be read: $($_.Exception.Message)" }
    if ([string]$toolkitManifest.ModuleVersion -ne $requiredVersion) { throw 'Bundled toolkit version does not match required version.' }
    $rootModule = [string]$toolkitManifest.RootModule
    if ([string]::IsNullOrWhiteSpace($rootModule) -or [IO.Path]::IsPathRooted($rootModule) -or $rootModule.IndexOfAny([char[]]@('\','/')) -ge 0) { throw 'Bundled toolkit manifest must name a direct-child RootModule.' }
    [void](Require-File (Join-Path (Split-Path -Parent $resolved.ToolkitManifest) $rootModule) 'toolkit root module')
    if (-not [string]::Equals((Get-FileHash -LiteralPath $resolved.Payload -Algorithm SHA256).Hash, $expectedHash, [StringComparison]::OrdinalIgnoreCase)) { throw 'Packaged installer hash does not match the source manifest.' }
    $receiptPath = Join-Path $packagePath 'PSPackageForgeReceipt.json'
    [void](Require-File $receiptPath 'receipt')
    try { $receipt = Get-Content -LiteralPath $receiptPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { throw "Package receipt is malformed JSON: $($_.Exception.Message)" }
    if ([string](Get-Value $receipt 'SchemaVersion') -ne '__RECEIPT_SCHEMA_VERSION__') { throw "Package receipt schema must be exactly '__RECEIPT_SCHEMA_VERSION__'." }
    foreach ($section in @('Generator','Renderer')) { $row=Get-Value $receipt $section; $name=if($section -eq 'Renderer'){'PSADT'}else{'PSPackageForge'}; if ([string](Get-Value $row 'Name') -ne $name -or [string](Get-Value $row 'Version') -ne '__GENERATOR_VERSION__') { throw "Package receipt $section metadata is invalid." } }
    $source = Get-Value $receipt 'SourceManifest'
    if ([string](Get-Value $source 'SHA256') -ne (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -or [string](Get-Value $source 'FileName') -ne 'PackageManifest.json' -or [string](Get-Value $source 'SchemaVersion') -ne '__MANIFEST_SCHEMA_VERSION__') { throw 'Package receipt source manifest hash or filename is stale.' }
    $toolkit = Get-Value $receipt 'Toolkit'
    if ([string](Get-Value $toolkit 'Version') -ne $requiredVersion -or [string](Get-Value $toolkit 'ModuleManifestPath') -ne $relative.ToolkitManifest) { throw 'Package receipt toolkit metadata does not match the required toolkit.' }
    $rows = @($receipt.Files); if ($rows.Count -eq 0) { throw 'Package receipt file inventory is empty.' }
    $recorded = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows) { $rel=[string]$row.Path; $length=$row.Length; $hash=[string]$row.SHA256; if ([string]::IsNullOrWhiteSpace($rel) -or $rel.StartsWith('/') -or $rel.Contains('\') -or $rel.Split('/') -contains '..' -or $recorded.ContainsKey($rel) -or $length -is [bool] -or $null -eq $length -or $hash -notmatch '^[0-9A-Fa-f]{64}$') { throw 'Package receipt contains an invalid or duplicate file inventory entry.' }; $recorded[$rel]=$row }
    $actual = @(Get-ChildItem -LiteralPath $packagePath -File -Recurse -Force -ErrorAction Stop | Where-Object { $_.FullName -ne $receiptPath })
    if ($actual.Count -ne $recorded.Count) { throw 'Package file set does not exactly match the receipt inventory.' }
    foreach ($file in $actual) { $rel=Get-RelativePath $packagePath $file.FullName; if (-not $recorded.ContainsKey($rel)) { throw "Package contains an unrecorded file '$rel'." }; $row=$recorded[$rel]; if ([int64]$row.Length -ne [int64]$file.Length) { throw "Package file length mismatch for '$rel'." }; if (-not [string]::Equals((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash,[string]$row.SHA256,[StringComparison]::OrdinalIgnoreCase)) { throw "Package file hash mismatch for '$rel'." } }
}
function Quote-WindowsToken([string] $Token) {
    if ($Token.Length -gt 0 -and $Token -notmatch '[\s"]') { return $Token }
    $builder = [Text.StringBuilder]::new(); [void]$builder.Append('"'); $slashes=0
    foreach ($character in $Token.ToCharArray()) { if ($character -eq '\') { $slashes++; continue }; if ($character -eq '"') { [void]$builder.Append(('\' * (2*$slashes+1))); [void]$builder.Append('"'); $slashes=0; continue }; if ($slashes) { [void]$builder.Append(('\' * $slashes)); $slashes=0 }; [void]$builder.Append($character) }
    if ($slashes) { [void]$builder.Append(('\' * (2*$slashes))) }; [void]$builder.Append('"'); return $builder.ToString()
}
function Join-WindowsTokens([string[]] $Tokens) { return (($Tokens | ForEach-Object { Quote-WindowsToken $_ }) -join ' ') }
Assert-PackageEvidence
if (Test-Path -LiteralPath $outputPath -ErrorAction Stop) { if (-not (Test-Path -LiteralPath $outputPath -PathType Container -ErrorAction Stop) -or @(Get-ChildItem -LiteralPath $outputPath -Force -ErrorAction Stop).Count -gt 0) { throw "IntuneWin output must be absent or an empty directory: '$outputPath'." } }
if ([string]::IsNullOrWhiteSpace($IntuneWinAppUtilPath)) { $commands=@(Get-Command -Name 'IntuneWinAppUtil.exe' -CommandType Application -All -ErrorAction SilentlyContinue); $paths=@($commands | ForEach-Object { if($_.Path){$_.Path}elseif($_.Source){$_.Source} } | Where-Object {$_} | Sort-Object -Unique); if($paths.Count -ne 1){throw "Expected exactly one IntuneWinAppUtil.exe on PATH; found $($paths.Count)."}; $IntuneWinAppUtilPath=$paths[0] } else { if(-not(Test-Path -LiteralPath $IntuneWinAppUtilPath -PathType Leaf)){throw "IntuneWinAppUtilPath was not found: '$IntuneWinAppUtilPath'."}; $IntuneWinAppUtilPath=(Resolve-Path -LiteralPath $IntuneWinAppUtilPath).ProviderPath }
$stagePath = Join-Path $root ('.IntuneWin-stage-' + [Guid]::NewGuid().ToString('N'))
$backupPath = $null
$stageCreated = $false
try {
    if (Test-Path -LiteralPath $stagePath -ErrorAction Stop) { throw "IntuneWin staging path already exists: '$stagePath'." }
    [void](New-Item -ItemType Directory -Path $stagePath -ErrorAction Stop)
    $stageCreated = $true
    $tokens=@('-c',$packagePath,'-s','Invoke-AppDeployToolkit.exe','-o',$stagePath,'-q')
    $arguments=Join-WindowsTokens $tokens
    $process=Start-Process -FilePath $IntuneWinAppUtilPath -ArgumentList $arguments -WorkingDirectory $root -Wait -PassThru
    if($process.ExitCode -ne 0){throw "IntuneWinAppUtil.exe failed with exit code $($process.ExitCode)."}
    $stageEntries=@(Get-ChildItem -LiteralPath $stagePath -Force -ErrorAction Stop)
    $outputs=@($stageEntries | Where-Object { -not $_.PSIsContainer -and $_.Name -like '*.intunewin' })
    if ($stageEntries.Count -ne 1) { throw "IntuneWinAppUtil.exe produced extra files or directories in staging; found $($stageEntries.Count) entries." }
    if($outputs.Count -ne 1 -or -not [string]::Equals($outputs[0].Name,'Invoke-AppDeployToolkit.intunewin',[StringComparison]::OrdinalIgnoreCase) -or $outputs[0].Length -le 0){throw "Expected exactly one non-empty Invoke-AppDeployToolkit.intunewin; found $($outputs.Count)."}
    if(Test-Path -LiteralPath $outputPath -ErrorAction Stop){if(-not(Test-Path -LiteralPath $outputPath -PathType Container -ErrorAction Stop) -or @(Get-ChildItem -LiteralPath $outputPath -Force -ErrorAction Stop).Count -gt 0){throw 'IntuneWin output changed or became nonempty during build.'}; $backupPath=Join-Path $root ('.IntuneWin-empty-' + [Guid]::NewGuid().ToString('N')); [IO.Directory]::Move($outputPath,$backupPath)}
    try { [IO.Directory]::Move($stagePath,$outputPath); $stageCreated=$false } catch { if($backupPath -and (Test-Path -LiteralPath $backupPath -ErrorAction Stop) -and -not(Test-Path -LiteralPath $outputPath -ErrorAction Stop)){[IO.Directory]::Move($backupPath,$outputPath);$backupPath=$null}; throw }
    if($backupPath -and (Test-Path -LiteralPath $backupPath)){[IO.Directory]::Delete($backupPath);$backupPath=$null}
    Write-Output (Join-Path $outputPath $outputs[0].Name)
} finally {
    if($stageCreated -and $stagePath -and (Test-Path -LiteralPath $stagePath -ErrorAction Stop)){Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction Stop}
    if($backupPath -and (Test-Path -LiteralPath $backupPath) -and -not(Test-Path -LiteralPath $outputPath)){[IO.Directory]::Move($backupPath,$outputPath)}
}
'@
    return $template.Replace('__MANIFEST_SCHEMA_VERSION__', [string]$script:ManifestSchemaVersion).
        Replace('__GENERATOR_VERSION__', [string]$script:GeneratorVersion).
        Replace('__REQUIRED_PSADT_VERSION__', [string]$script:RequiredPSADTVersion).
        Replace('__RECEIPT_SCHEMA_VERSION__', [string]$script:PackageReceiptSchemaVersion)

}

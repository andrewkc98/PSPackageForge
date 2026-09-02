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
    return @'
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
$sourceSetup = Join-Path $packagePath 'Invoke-AppDeployToolkit.exe'
$sourceScript = Join-Path $packagePath 'Invoke-AppDeployToolkit.ps1'
$filesPath = Join-Path $packagePath 'Files'
$outputPath = Join-Path $root 'IntuneWin'
function Assert-Leaf([string] $path, [string] $description) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$description was not found: '$path'." }
}
function Assert-Directory([string] $path, [string] $description) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "$description was not found: '$path'." }
}
function Resolve-DirectFile([string] $name) {
    if ([string]::IsNullOrWhiteSpace($name) -or $name.IndexOfAny([char[]]@('\', '/')) -ge 0 -or [System.IO.Path]::IsPathRooted($name) -or $name -eq '.' -or $name -eq '..') { throw 'Installer.FileName must be one direct child filename.' }
    return Join-Path $filesPath $name
}
Assert-Leaf $manifestPath 'PackageManifest.json'
try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } catch { throw "PackageManifest.json is malformed JSON: $($_.Exception.Message)" }
if ("$($manifest.SchemaVersion)" -ne '1.0') { throw "PackageManifest.json schema must be '1.0'." }
if ("$($manifest.Readiness)" -ne 'ReviewRequired') { throw "PackageManifest.json readiness must be 'ReviewRequired'." }
if ($null -eq $manifest.Installer) { throw 'PackageManifest.json is missing Installer.' }
$fileName = "$($manifest.Installer.FileName)"
$manifestPathValue = "$($manifest.Installer.Path)"
$expectedHash = "$($manifest.Installer.SHA256)"
if ($fileName -ne $manifestPathValue -or [string]::IsNullOrWhiteSpace($expectedHash) -or $expectedHash -notmatch '^[0-9A-Fa-f]{64}$') { throw 'Installer.Path, Installer.FileName, and Installer.SHA256 are invalid.' }
$stagedInstallerPath = Join-Path $root $fileName
Assert-Leaf $stagedInstallerPath 'Staged installer'
$installerPath = Resolve-DirectFile $fileName
Assert-Directory $packagePath 'Package directory'
Assert-Leaf $sourceSetup 'PSADT executable'
Assert-Leaf $sourceScript 'PSADT script'
Assert-Directory $filesPath 'Package/Files directory'
Assert-Leaf $installerPath 'Packaged installer'
$stagedHash = (Get-FileHash -LiteralPath $stagedInstallerPath -Algorithm SHA256).Hash
if (-not [string]::Equals($stagedHash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Staged installer hash mismatch. Expected $expectedHash, got $stagedHash." }
$actualHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
if (-not [string]::Equals($actualHash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Packaged installer hash mismatch. Expected $expectedHash, got $actualHash." }
if (Test-Path -LiteralPath $outputPath) {
    if (-not (Test-Path -LiteralPath $outputPath -PathType Container) -or @(Get-ChildItem -LiteralPath $outputPath -Force).Count -gt 0) { throw "IntuneWin output must be absent or an empty directory: '$outputPath'." }
} else { [void](New-Item -ItemType Directory -Path $outputPath) }
if ([string]::IsNullOrWhiteSpace($IntuneWinAppUtilPath)) {
    $commands = @(Get-Command -Name 'IntuneWinAppUtil.exe' -CommandType Application -All -ErrorAction SilentlyContinue)
    $paths = @($commands | ForEach-Object { if ($_.Path) { $_.Path } elseif ($_.Source) { $_.Source } } | Where-Object { $_ } | Sort-Object -Unique)
    if ($paths.Count -ne 1) { throw "Expected exactly one IntuneWinAppUtil.exe on PATH; found $($paths.Count)." }
    $IntuneWinAppUtilPath = $paths[0]
} else {
    Assert-Leaf $IntuneWinAppUtilPath 'IntuneWinAppUtilPath'
    $IntuneWinAppUtilPath = (Resolve-Path -LiteralPath $IntuneWinAppUtilPath).ProviderPath
}
$arguments = @('-c', $packagePath, '-s', 'Invoke-AppDeployToolkit.exe', '-o', $outputPath, '-q')
$process = Start-Process -FilePath $IntuneWinAppUtilPath -ArgumentList $arguments -WorkingDirectory $root -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "IntuneWinAppUtil.exe failed with exit code $($process.ExitCode)." }
$outputs = @(Get-ChildItem -LiteralPath $outputPath -Filter "*.intunewin" -File -ErrorAction SilentlyContinue)
if ($outputs.Count -ne 1 -or -not [string]::Equals($outputs[0].Name, "Invoke-AppDeployToolkit.intunewin", [System.StringComparison]::OrdinalIgnoreCase) -or $outputs[0].Length -le 0) { throw "Expected exactly one non-empty Invoke-AppDeployToolkit.intunewin; found $($outputs.Count)." }
Write-Output $outputs[0].FullName
'@
}

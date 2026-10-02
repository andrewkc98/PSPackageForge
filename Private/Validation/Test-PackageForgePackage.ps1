function Test-PackageForgePackage {
    <#
        Verify a locally generated package against its source manifest and receipt.
        This detects accidental staleness and edits within one operator's workspace; it is
        not a signature and does not protect against a malicious local editor.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNull()] [object] $ManifestInput,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $PackagePath
    )

    function Get-Value {
        param([object] $InputObject, [string] $Name)
        if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }
        return Get-DocumentOptionalProperty -InputObject $InputObject -Name $Name
    }

    function Get-CanonicalPath {
        param([string] $Path)
        return [System.IO.Path]::GetFullPath(
            $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
    }

    function Get-RelativePath {
        param([string] $Root, [string] $Path)
        $prefix = $Root.TrimEnd([char[]] @('/', '\')) + [System.IO.Path]::DirectorySeparatorChar
        return $Path.Substring($prefix.Length).Replace('\', '/')
    }

    function Assert-PackageFile {
        param([string] $Path, [string] $Description)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw [System.IO.InvalidDataException]::new("Package is missing required $Description '$Path'.")
        }
        return Get-Item -LiteralPath $Path -Force
    }

    $packageRoot = Get-CanonicalPath $PackagePath
    if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new("Package path was not found: '$packageRoot'.")
    }
    $packageRoot = (Resolve-Path -LiteralPath $packageRoot -ErrorAction Stop).ProviderPath

    $manifestPath = Get-CanonicalPath ([string] (Get-Value $ManifestInput 'ManifestPath'))
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("Source manifest was not found: '$manifestPath'.")
    }
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not [string]::Equals($manifestHash, [string] (Get-Value $ManifestInput 'ManifestSHA256'), [StringComparison]::OrdinalIgnoreCase)) {
        throw [System.IO.InvalidDataException]::new('The source manifest changed after it was read; package validation requires a fresh manifest result.')
    }
    $manifest = Get-Value $ManifestInput 'Manifest'
    $installer = Get-Value $manifest 'Installer'
    $installerName = [string] (Get-Value $installer 'FileName')
    if ([string]::IsNullOrWhiteSpace($installerName) -or [System.IO.Path]::IsPathRooted($installerName) -or
        $installerName.IndexOfAny([char[]] @('/', '\')) -ge 0) {
        throw [System.IO.InvalidDataException]::new('Source manifest must identify a direct-child installer filename.')
    }

    $scaffoldInstaller = Get-CanonicalPath ([string] (Get-Value $ManifestInput 'InstallerPath'))
    [void] (Assert-PackageFile $scaffoldInstaller 'scaffolded installer')
    $scaffoldExpectedHash = [string] (Get-Value $installer 'SHA256')
    $scaffoldActualHash = (Get-FileHash -LiteralPath $scaffoldInstaller -Algorithm SHA256).Hash
    if (-not [string]::Equals($scaffoldActualHash, $scaffoldExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw [System.IO.InvalidDataException]::new('The scaffolded installer hash does not match the source manifest.')
    }
    $requiredToolkitVersion = [string] (Get-Value $ManifestInput 'RequiredPSADTVersion')
    if ([string]::IsNullOrWhiteSpace($requiredToolkitVersion) -or $requiredToolkitVersion -ne "$script:RequiredPSADTVersion") {
        throw [System.IO.InvalidDataException]::new("The source manifest toolkit requirement must be exactly $script:RequiredPSADTVersion.")
    }

    $relativePaths = [ordered] @{
        Launcher = 'Invoke-AppDeployToolkit.exe'
        Frontend = 'Invoke-AppDeployToolkit.ps1'
        Config = 'Config/config.psd1'
        ToolkitManifest = 'PSAppDeployToolkit/PSAppDeployToolkit.psd1'
        Payload = "Files/$installerName"
    }
    $resolved = @{}
    foreach ($key in $relativePaths.Keys) {
        $path = Join-Path $packageRoot ($relativePaths[$key] -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $file = Assert-PackageFile $path $key.ToLowerInvariant()
        if ($file.Length -eq 0) { throw [System.IO.InvalidDataException]::new("Package $($key.ToLowerInvariant()) is empty.") }
        $resolved[$key] = $file.FullName
    }
    $launcherBytes = [System.IO.File]::ReadAllBytes($resolved.Launcher)
    if ($launcherBytes.Length -lt 68 -or $launcherBytes[0] -ne 0x4D -or $launcherBytes[1] -ne 0x5A) {
        throw [System.IO.InvalidDataException]::new('Package launcher is not a valid PE executable.')
    }
    $peOffset = [BitConverter]::ToInt32($launcherBytes, 0x3C)
    if ($peOffset -lt 64 -or $peOffset -gt ($launcherBytes.Length - 4) -or
        $launcherBytes[$peOffset] -ne 0x50 -or $launcherBytes[$peOffset + 1] -ne 0x45 -or
        $launcherBytes[$peOffset + 2] -ne 0 -or $launcherBytes[$peOffset + 3] -ne 0) {
        throw [System.IO.InvalidDataException]::new('Package launcher is not a valid PE executable.')
    }
    $frontendText = [System.IO.File]::ReadAllText($resolved.Frontend)
    $parseTokens = $null
    $parseErrors = $null
    $frontendAst = [System.Management.Automation.Language.Parser]::ParseInput($frontendText, [ref] $parseTokens, [ref] $parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw [System.IO.InvalidDataException]::new('Package frontend contains PowerShell parse errors.')
    }
    foreach ($functionName in @('Install-ADTDeployment', 'Uninstall-ADTDeployment')) {
        $definitions = @($frontendAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true))
        if ($definitions.Count -ne 1) {
            throw [System.IO.InvalidDataException]::new("Package frontend must contain exactly one function '$functionName'.")
        }
    }

    try { $toolkitManifest = Import-PowerShellDataFile -LiteralPath $resolved.ToolkitManifest -ErrorAction Stop }
    catch { throw [System.IO.InvalidDataException]::new("Bundled toolkit manifest could not be read: $($_.Exception.Message)") }
    $toolkitVersion = [string] (Get-Value $toolkitManifest 'ModuleVersion')
    if ($toolkitVersion -ne $requiredToolkitVersion) {
        throw [System.IO.InvalidDataException]::new("Bundled toolkit version '$toolkitVersion' does not match required version '$requiredToolkitVersion'.")
    }
    $rootModule = [string] (Get-Value $toolkitManifest 'RootModule')
    if ([string]::IsNullOrWhiteSpace($rootModule) -or [System.IO.Path]::IsPathRooted($rootModule) -or
        $rootModule.IndexOfAny([char[]] @('/', '\')) -ge 0) {
        throw [System.IO.InvalidDataException]::new('Bundled toolkit manifest must name a direct-child RootModule.')
    }
    $toolkitRoot = Split-Path -Parent $resolved.ToolkitManifest
    [void] (Assert-PackageFile (Join-Path $toolkitRoot $rootModule) 'toolkit root module')

    $payloadHash = (Get-FileHash -LiteralPath $resolved.Payload -Algorithm SHA256).Hash
    if (-not [string]::Equals($payloadHash, $scaffoldExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw [System.IO.InvalidDataException]::new('Packaged installer hash does not match the scaffolded installer.')
    }

    $receiptPath = Join-Path $packageRoot 'PSPackageForgeReceipt.json'
    [void] (Assert-PackageFile $receiptPath 'receipt')
    try { $receipt = Get-Content -LiteralPath $receiptPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { throw [System.IO.InvalidDataException]::new("Package receipt is malformed JSON: $($_.Exception.Message)") }
    if ([string] (Get-Value $receipt 'SchemaVersion') -ne "$script:PackageReceiptSchemaVersion") {
        throw [System.IO.InvalidDataException]::new("Package receipt schema must be exactly $script:PackageReceiptSchemaVersion.")
    }
    $renderer = Get-Value $receipt 'Renderer'
    if ([string] (Get-Value $renderer 'Name') -ne 'PSADT' -or
        [string] (Get-Value $renderer 'Version') -ne "$script:GeneratorVersion") {
        throw [System.IO.InvalidDataException]::new("Package receipt renderer version must be exactly $script:GeneratorVersion.")
    }
    $generator = Get-Value $receipt 'Generator'
    if ([string] (Get-Value $generator 'Name') -ne 'PSPackageForge' -or
        [string] (Get-Value $generator 'Version') -ne "$script:GeneratorVersion") {
        throw [System.IO.InvalidDataException]::new("Package receipt generator version must be exactly $script:GeneratorVersion.")
    }
    $source = Get-Value $receipt 'SourceManifest'
    if ([string] (Get-Value $source 'SHA256') -ne $manifestHash -or
        [string] (Get-Value $source 'FileName') -ne [System.IO.Path]::GetFileName($manifestPath) -or
        [string] (Get-Value $source 'SchemaVersion') -ne "$script:ManifestSchemaVersion") {
        throw [System.IO.InvalidDataException]::new('Package receipt source manifest hash or filename is stale.')
    }
    $toolkit = Get-Value $receipt 'Toolkit'
    if ([string] (Get-Value $toolkit 'Version') -ne $requiredToolkitVersion -or
        [string] (Get-Value $toolkit 'ModuleManifestPath') -ne $relativePaths.ToolkitManifest) {
        throw [System.IO.InvalidDataException]::new('Package receipt toolkit metadata does not match the required toolkit.')
    }

    $rows = @(Get-Value $receipt 'Files')
    if ($rows.Count -eq 0) { throw [System.IO.InvalidDataException]::new('Package receipt file inventory is empty.') }
    $recorded = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows) {
        $relative = [string] (Get-Value $row 'Path')
        $lengthValue = Get-Value $row 'Length'
        $hashValue = [string] (Get-Value $row 'SHA256')
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('/') -or $relative.Contains('\') -or
            $relative.Split('/') -contains '..' -or $recorded.ContainsKey($relative) -or
            $lengthValue -is [bool] -or $null -eq $lengthValue -or $hashValue -notmatch '^[0-9A-Fa-f]{64}$') {
            throw [System.IO.InvalidDataException]::new('Package receipt contains an invalid or duplicate file inventory entry.')
        }
        $recorded.Add($relative, $row)
    }
    $actualFiles = @(Get-ChildItem -LiteralPath $packageRoot -File -Recurse -Force | Where-Object { $_.FullName -ne $receiptPath })
    if ($actualFiles.Count -ne $recorded.Count) {
        throw [System.IO.InvalidDataException]::new('Package file set does not exactly match the receipt inventory.')
    }
    foreach ($file in $actualFiles) {
        $relative = Get-RelativePath $packageRoot $file.FullName
        if (-not $recorded.ContainsKey($relative)) {
            throw [System.IO.InvalidDataException]::new("Package contains an unrecorded file '$relative'.")
        }
        $row = $recorded[$relative]
        if ([int64] (Get-Value $row 'Length') -ne [int64] $file.Length) {
            throw [System.IO.InvalidDataException]::new("Package file length mismatch for '$relative'.")
        }
        $actualHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if (-not [string]::Equals($actualHash, [string] (Get-Value $row 'SHA256'), [StringComparison]::OrdinalIgnoreCase)) {
            throw [System.IO.InvalidDataException]::new("Package file hash mismatch for '$relative'.")
        }
    }

    [pscustomobject] ([ordered] @{
        PackagePath = $packageRoot
        LauncherPath = $resolved.Launcher
        FrontendPath = $resolved.Frontend
        ConfigPath = $resolved.Config
        ToolkitManifestPath = $resolved.ToolkitManifest
        PayloadPath = $resolved.Payload
        ReceiptPath = $receiptPath
    })
}

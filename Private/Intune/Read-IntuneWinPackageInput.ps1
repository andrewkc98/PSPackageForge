function Read-IntuneWinPackageInput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputPath)
    function Resolve-ExistingFile([string] $Path, [string] $Description) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw [System.IO.FileNotFoundException]::new("$Description was not found: '$Path'.") }
        return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    }
    function Resolve-WithinRoot([string] $Root, [string] $Relative, [string] $Description) {
        if ([string]::IsNullOrWhiteSpace($Relative) -or [System.IO.Path]::IsPathRooted($Relative)) { throw [System.IO.InvalidDataException]::new("$Description must be a relative path within the scaffold root.") }
        $parts = $Relative -split '[\\/]'
        if ($parts | Where-Object { $_ -eq '..' -or $_ -eq '.' -or [string]::IsNullOrWhiteSpace($_) }) { throw [System.IO.InvalidDataException]::new("$Description contains invalid traversal segments: '$Relative'.") }
        $candidate = [System.IO.Path]::GetFullPath((Join-Path -Path $Root -ChildPath ($Relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
        $prefix = $Root.TrimEnd([char[]] @([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw [System.IO.InvalidDataException]::new("$Description resolves outside the scaffold root.") }
        return $candidate
    }
    $root = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath))
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw [System.IO.DirectoryNotFoundException]::new("Scaffold root was not found: '$root'.") }
    $manifestPath = Resolve-ExistingFile (Join-Path $root 'PackageManifest.json') 'PackageManifest.json'
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { throw [System.IO.InvalidDataException]::new("PackageManifest.json is malformed JSON: $($_.Exception.Message)") }
    if ("$($manifest.SchemaVersion)" -ne '1.0') { throw [System.IO.InvalidDataException]::new("PackageManifest.json schema '$($manifest.SchemaVersion)' is not supported; expected '1.0'.") }
    if ("$($manifest.Readiness)" -ne 'ReviewRequired') { throw [System.InvalidOperationException]::new("PackageManifest.json readiness is '$($manifest.Readiness)'; expected 'ReviewRequired'.") }
    $installer = $manifest.Installer; $fileName = "$($installer.FileName)"; $pathText = "$($installer.Path)"; $expectedHash = "$($installer.SHA256)"
    $separators = [char[]] @('\', '/')
    if ([string]::IsNullOrWhiteSpace($fileName) -or [string]::IsNullOrWhiteSpace($pathText) -or [string]::IsNullOrWhiteSpace($expectedHash) -or
        $fileName -ne $pathText -or $fileName.IndexOfAny($separators) -ge 0 -or $pathText.IndexOfAny($separators) -ge 0 -or
        [System.IO.Path]::IsPathRooted($fileName) -or [System.IO.Path]::IsPathRooted($pathText) -or
        $fileName -eq '.' -or $fileName -eq '..') {
        throw [System.IO.InvalidDataException]::new('PackageManifest.json Installer.Path and Installer.FileName must match one direct child filename and include Installer.SHA256.')
    }
    $stagedInstallerPath = Resolve-ExistingFile (Resolve-WithinRoot -Root $root -Relative $pathText -Description 'Installer.Path') 'Staged installer'
    $sourceHash = (Get-FileHash -LiteralPath $stagedInstallerPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($sourceHash, $expectedHash, [StringComparison]::OrdinalIgnoreCase)) { throw [System.IO.InvalidDataException]::new("Staged installer hash mismatch. Expected $expectedHash, got $sourceHash.") }
    $packageRoot = Resolve-WithinRoot -Root $root -Relative 'Package' -Description 'Package directory'
    if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) { throw [System.IO.DirectoryNotFoundException]::new("Package directory was not found: '$packageRoot'.") }
    $setupExe = Resolve-ExistingFile (Join-Path $packageRoot 'Invoke-AppDeployToolkit.exe') 'PSADT executable'
    $setupScript = Resolve-ExistingFile (Join-Path $packageRoot 'Invoke-AppDeployToolkit.ps1') 'PSADT script'
    $packagedPath = Resolve-ExistingFile (Resolve-WithinRoot -Root $root -Relative (Join-Path 'Package/Files' $fileName) -Description 'Packaged installer') 'Packaged installer'
    $packagedHash = (Get-FileHash -LiteralPath $packagedPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($packagedHash, $expectedHash, [StringComparison]::OrdinalIgnoreCase)) { throw [System.IO.InvalidDataException]::new("Packaged installer hash mismatch. Expected $expectedHash, got $packagedHash.") }
    $intuneWinPath = Join-Path $root 'IntuneWin'
    if (Test-Path -LiteralPath $intuneWinPath) {
        if (-not (Test-Path -LiteralPath $intuneWinPath -PathType Container) -or @(Get-ChildItem -LiteralPath $intuneWinPath -Force).Count -gt 0) { throw [System.IO.IOException]::new("IntuneWin output '$intuneWinPath' must be absent or an empty directory; existing content will not be removed or overwritten.") }
    }
    [PSCustomObject]@{ ManifestPath=$manifestPath; SourcePath=$packageRoot; StagedInstallerPath=$stagedInstallerPath; SetupExecutablePath=$setupExe; SetupScriptPath=$setupScript; PackagePath=$packageRoot; InstallerPath=$packagedPath; InstallerFileName=$fileName; SHA256=$expectedHash.ToUpperInvariant(); OutputPath=$root; IntuneWinPath=$intuneWinPath }
}

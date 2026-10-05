function Read-IntuneWinPackageInput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $OutputPath)

    $root = [System.IO.Path]::GetFullPath(
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath))
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw [System.IO.DirectoryNotFoundException]::new("Scaffold root was not found: '$root'.")
    }

    $manifestInput = Read-PackageForgeManifest -ManifestPath (Join-Path $root 'PackageManifest.json') -RequireRunnable
    $validatedPackage = Test-PackageForgePackage -ManifestInput $manifestInput -PackagePath (Join-Path $root 'Package')
    $installer = Get-DocumentOptionalProperty -InputObject $manifestInput.Manifest -Name 'Installer'
    $installerFileName = [string] (Get-DocumentOptionalProperty -InputObject $installer -Name 'FileName')
    $intuneWinPath = Join-Path $root 'IntuneWin'

    # Destination occupancy is action-specific: reusable package integrity is handled above,
    # while an existing IntuneWin destination is only accepted when it is an empty directory.
    if (Test-Path -LiteralPath $intuneWinPath) {
        if (-not (Test-Path -LiteralPath $intuneWinPath -PathType Container) -or
            @(Get-ChildItem -LiteralPath $intuneWinPath -Force).Count -gt 0) {
            throw [System.IO.IOException]::new(
                "IntuneWin output '$intuneWinPath' must be absent or an empty directory; existing content will not be removed or overwritten.")
        }
    }

    [PSCustomObject]@{
        ManifestPath = $manifestInput.ManifestPath
        SourcePath = $validatedPackage.PackagePath
        StagedInstallerPath = $manifestInput.InstallerPath
        SetupExecutablePath = $validatedPackage.LauncherPath
        SetupScriptPath = $validatedPackage.FrontendPath
        PackagePath = $validatedPackage.PackagePath
        InstallerPath = $validatedPackage.PayloadPath
        InstallerFileName = $installerFileName
        SHA256 = ([string] (Get-DocumentOptionalProperty -InputObject $installer -Name 'SHA256')).ToUpperInvariant()
        OutputPath = $root
        IntuneWinPath = $intuneWinPath
    }
}

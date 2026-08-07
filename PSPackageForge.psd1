@{
    RootModule           = 'PSPackageForge.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '28b493a7-3b39-4fa0-a7d9-e4eb65a02c69'

    Author               = 'Andrew Tucker'
    CompanyName          = 'Unknown'
    Copyright            = '(c) Andrew Tucker. All rights reserved.'

    Description          = 'Offline MECM/Intune packaging scaffolder. Identifies an installer, gathers evidence with per-field provenance, resolves install/uninstall/detection decisions, and emits a reviewable packaging bundle. Never emits a confident wrong answer: unresolved critical decisions block runnable output rather than receiving a default.'

    # 5.1 is non-negotiable -- it is what MECM environments actually run.
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport    = @(
        'Get-InstallerInfo'
        'Get-InstalledAppInfo'
        'New-DetectionMethod'
        'New-PSADTPackage'
        'New-IntuneWinPackage'
        'New-PackageDocument'
        'New-PackageScaffold'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    FileList             = @(
        'PSPackageForge.psd1'
        'PSPackageForge.psm1'
    )

    PrivateData          = @{
        PSData = @{
            Tags         = @('MECM', 'ConfigMgr', 'SCCM', 'Intune', 'Packaging', 'PSADT', 'MSI', 'Deployment', 'Windows')
            ProjectUri   = 'https://github.com/andrewkc98/PSPackageForge'
            LicenseUri   = 'https://github.com/andrewkc98/PSPackageForge/blob/main/LICENSE'
            ReleaseNotes = 'Initial development release. Offline scaffolding only; see the roadmap in README.md for deferred features.'
        }

        # Pinned toolchain versions. Recorded in every PackageManifest.json so a generated
        # package can always be traced back to the exact renderer that produced it.
        PSPackageForge = @{
            ManifestSchemaVersion  = '1.0'
            DiscoverySchemaVersion = '1.0'
            RequiredPSADTVersion   = '4.0.6'
        }
    }
}

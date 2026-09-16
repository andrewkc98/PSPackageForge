@{
    RootModule           = 'PSPackageForge.psm1'
    ModuleVersion        = '0.2.0'
    GUID                 = '28b493a7-3b39-4fa0-a7d9-e4eb65a02c69'

    Author               = 'Andrew Tucker'
    CompanyName          = 'Unknown'
    Copyright            = '(c) Andrew Tucker. All rights reserved.'

    Description          = 'Preview 0.2 offline MECM/Intune packaging scaffolder. Identifies an installer, gathers evidence with per-field provenance, resolves install/uninstall/detection decisions, and emits a reviewable packaging bundle. Active critical blockers are reported, and runnable output fails closed while blockers remain unmet; no deployment guarantee is provided.'

    # 5.1 is non-negotiable -- it is what MECM environments actually run.
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport    = @(
        'Get-InstallerInfo'
        'Get-InstalledAppInfo'
        'New-DetectionMethod'
        'New-PSADTPackage'
        'New-IntuneWinPackage'
        'New-MecmDeploymentSpec'
        'New-PackageDocument'
        'New-PackageScaffold'
        'Invoke-PackageForge'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('psforge')

    FileList             = @(
        'PSPackageForge.psd1'
        'PSPackageForge.psm1'
    )

    PrivateData          = @{
        PSData = @{
            Tags         = @('MECM', 'ConfigMgr', 'SCCM', 'Intune', 'Packaging', 'PSADT', 'MSI', 'Deployment', 'Windows')
            ProjectUri   = 'https://github.com/andrewkc98/PSPackageForge'
            LicenseUri   = 'https://github.com/andrewkc98/PSPackageForge/blob/main/LICENSE'
            ReleaseNotes = 'Preview 0.2 initial-development release. Offline scaffolding records evidence provenance and active critical blockers, and fails closed for runnable output when blockers remain unmet. No deployment guarantee; see the roadmap in README.md for deferred features.'
        }

        # Pinned toolchain versions. Recorded in every PackageManifest.json so a generated
        # package can always be traced back to the exact renderer that produced it.
        PSPackageForge = @{
            ManifestSchemaVersion      = '2.0'
            DiscoverySchemaVersion     = '2.0'
            PackageReceiptSchemaVersion = '1.0'
            RequiredPSADTVersion       = '4.0.6'
        }
    }
}

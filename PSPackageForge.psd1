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
        'Config/known-quirks.psd1'
        'Config/settings.example.psd1'
        'Private/ConvertTo-ForgeComparableValue.ps1'
        'Private/ConvertTo-ForgeDisplayValue.ps1'
        'Private/Get-DocumentOptionalProperty.ps1'
        'Private/Get-ForgeEnumValue.ps1'
        'Private/Get-InstallerContainerType.ps1'
        'Private/Get-InstallerSignature.ps1'
        'Private/Intune/ConvertTo-IntuneWinBuildScript.ps1'
        'Private/Intune/Invoke-IntuneWinAppUtil.ps1'
        'Private/Intune/Read-IntuneWinPackageInput.ps1'
        'Private/Intune/Resolve-IntuneWinAppUtil.ps1'
        'Private/New-ForgeFinding.ps1'
        'Private/PSADT/Resolve-PSADTTemplateCommand.ps1'
        'Private/Providers/Add-ForgeInstalledAppEvidence.ps1'
        'Private/Providers/ConvertTo-InstalledAppMatch.ps1'
        'Private/Providers/Get-ExeEvidence.ps1'
        'Private/Providers/Get-KnownQuirkEvidence.ps1'
        'Private/Providers/Get-MsiEvidence.ps1'
        'Private/Providers/Get-RegistryUninstallEntry.ps1'
        'Private/Providers/Invoke-MsiMember.ps1'
        'Private/Providers/Read-MsiDatabase.ps1'
        'Private/Providers/Read-PortableExecutableMetadata.ps1'
        'Private/Rendering/ConvertTo-CommandString.ps1'
        'Private/Rendering/ConvertTo-DetectionScript.ps1'
        'Private/Rendering/ConvertTo-MecmDeploymentSpec.ps1'
        'Private/Rendering/ConvertTo-PSADTConfigContent.ps1'
        'Private/Rendering/ConvertTo-PSADTTemplateContent.ps1'
        'Private/Rendering/ConvertTo-PackageDocumentContent.ps1'
        'Private/Rendering/Read-InstalledAppDiscoveryData.ps1'
        'Private/Rendering/Write-PackageManifest.ps1'
        'Private/Resolution/Merge-InstallerEvidence.ps1'
        'Private/Resolution/Resolve-DetectionSpec.ps1'
        'Private/Resolution/Resolve-MsiInstallPath.ps1'
        'Private/Resolution/Resolve-PackageSpec.ps1'
        'Private/Test-ScaffoldOutput.ps1'
        'Private/Validation/Read-PackageForgeManifest.ps1'
        'Private/Validation/Test-PackageForgePackage.ps1'
        'Private/Validation/Write-PackageForgeReceipt.ps1'
        'Public/Get-InstalledAppInfo.ps1'
        'Public/Get-InstallerInfo.ps1'
        'Public/Invoke-PackageForge.ps1'
        'Public/New-DetectionMethod.ps1'
        'Public/New-IntuneWinPackage.ps1'
        'Public/New-MecmDeploymentSpec.ps1'
        'Public/New-PSADTPackage.ps1'
        'Public/New-PackageDocument.ps1'
        'Public/New-PackageScaffold.ps1'
        'Templates/PackageDocument.md.template'
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

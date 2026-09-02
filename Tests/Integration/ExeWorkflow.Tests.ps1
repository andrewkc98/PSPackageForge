<#
    Deterministic public workflows for EXE installers plus discovered deployment
    context.  The EXEs are synthetic PE fixtures; this suite never executes them.
#>

$script:ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {
    Describe "Deterministic EXE discovery workflows" {
    BeforeAll {
        $script:ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:FixtureRoot = Join-Path $script:ModuleRoot 'Tests/Fixtures'

        $script:NativeFrontend = @'
$adtSession = @{
    AppVendor = ''
    AppName = ''
    AppVersion = ''
    AppArch = ''
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
}

function Install-ADTDeployment
{
    ## <Perform Installation tasks here>
}

function Uninstall-ADTDeployment
{
    ## <Perform Uninstallation tasks here>
}
'@

        $script:FakeTemplateCommand = {
            param([string] $Destination, [string] $Name, [int] $Version, [switch] $PassThru)
            if ($Version -ne 4) { throw 'The deterministic template seam only accepts v4.' }
            $packagePath = Join-Path $Destination $Name
            [void] (New-Item -ItemType Directory -Path (Join-Path $packagePath 'Files') -Force)
            Set-Content -LiteralPath (Join-Path $packagePath 'Invoke-AppDeployToolkit.ps1') `
                -Value $script:NativeFrontend -Encoding UTF8
            [void] (New-Item -ItemType File -Path (Join-Path $packagePath 'Invoke-AppDeployToolkit.exe') -Force)
            if ($PassThru) { Get-Item -LiteralPath $packagePath }
        }
    }

    BeforeEach {
        Mock Resolve-PSADTTemplateCommand { $script:FakeTemplateCommand }
    }

    It 'keeps KiCad NSIS profile evidence separate from system discovery context' {
        $output = Join-Path $TestDrive 'kicad-scaffold'
        $installer = Join-Path $script:FixtureRoot 'framework-stubs/nsis.exe'
        $discovery = Join-Path $script:FixtureRoot 'discovery/kicad.discovery.json'

        $scaffold = New-PackageScaffold -Path $installer -OutputPath $output -DiscoveryData $discovery
        $scaffold.Readiness | Should -Be 'ReviewRequired'
        $scaffold.ManifestPath | Should -Exist
        $scaffold.DetectionPath | Should -Exist

        $manifest = Get-Content -LiteralPath $scaffold.ManifestPath -Raw | ConvertFrom-Json
        $manifest | Should -Not -BeNullOrEmpty
        $manifest.SchemaVersion | Should -Be '1.0'
        $manifest.Readiness | Should -Be 'ReviewRequired'
        $manifest.Installer.ProductName | Should -Be 'KiCad Fixture'
        $manifest.Installer.ProductCode | Should -BeNullOrEmpty
        $manifest.PackageSpec.InstallCommand.Executable | Should -Be 'nsis.exe'
        @($manifest.PackageSpec.InstallCommand.ArgumentList) | Should -Be @('/S')
        $manifest.PackageSpec.SelectedContext | Should -Be 'System'
        $manifest.PackageSpec.RequiresLogonWhenUserContext | Should -BeFalse
        $manifest.PackageSpec.UninstallCommand.Executable | Should -Be '%ProgramFiles%\KiCad Fixture\uninstall.exe'
        ($manifest.PackageSpec.DetectionSpec[0].Path -replace '\\','/') | Should -Be '%ProgramFiles%/KiCad Fixture/bin'
        $manifest.PackageSpec.DetectionSpec[0].FileName | Should -Be 'kicad.exe'

        $installEvidence = @($manifest.Installer.Evidence | Where-Object Field -eq 'InstallCommand')
        $installEvidence[0].Source | Should -Be 'Inferred'
        $installEvidence[0].Value.ArgumentList | Should -Be @('/S')
        @($manifest.Installer.Evidence | Where-Object { $_.Field -eq 'ProductCode' }) | Should -HaveCount 0
        ($manifest.Installer.Evidence | Where-Object Field -eq 'InstallLocation').Source | Should -Be 'DiscoveryJson'
        ($manifest.Installer.Evidence | Where-Object Field -eq 'SelectedContext').Source | Should -Be 'DiscoveryJson'
        ($manifest.Installer.Evidence | Where-Object Field -eq 'UninstallCommand').Source | Should -Be 'DiscoveryJson'
        ($manifest.Installer.Evidence | Where-Object Field -eq 'DetectionTarget').Source | Should -Be 'DiscoveryJson'
        ($manifest.Installer.Evidence | Where-Object Field -eq 'InstallLocation').Notes | Should -Match 'Registry'

        $mecm = New-MecmDeploymentSpec -ManifestPath $scaffold.ManifestPath -ContentSourcePath 'Content/KiCad'
        $mecm.SpecPath | Should -Exist
        $mecmSpec = Get-Content -LiteralPath $mecm.SpecPath -Raw | ConvertFrom-Json
        $mecmSpec.DeploymentType[0].InstallCommand | Should -Be 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent -AllowRebootPassThru'
        $mecmSpec.DeploymentType[0].UserExperience.InstallBehavior | Should -Be 'InstallForSystem'
        $mecmSpec.DeploymentType[0].Detection | Should -Not -BeNullOrEmpty
        ($mecmSpec.Findings | Where-Object Code -eq 'MSI_PRODUCT_CODE_REQUIRED') | Should -BeNullOrEmpty

        $psadt = New-PSADTPackage -ManifestPath $scaffold.ManifestPath
        $psadt.DeploymentScriptPath | Should -Exist
        $content = Get-Content -LiteralPath $psadt.DeploymentScriptPath -Raw
        $content | Should -Match "Start-ADTProcess -FilePath 'nsis.exe' -ArgumentList @\('/S'\)"
        $content | Should -Not -Match 'msiexec'
    }

    It 'keeps Obsidian Squirrel profile evidence separate from per-user discovery context' {
        $output = Join-Path $TestDrive 'obsidian-scaffold'
        $installer = Join-Path $script:FixtureRoot 'framework-stubs/squirrel.exe'
        $discovery = Join-Path $script:FixtureRoot 'discovery/obsidian.discovery.json'

        $scaffold = New-PackageScaffold -Path $installer -OutputPath $output -DiscoveryData $discovery
        $scaffold.Readiness | Should -Be 'ReviewRequired'
        $scaffold.ManifestPath | Should -Exist
        $scaffold.DetectionPath | Should -Exist

        $manifest = Get-Content -LiteralPath $scaffold.ManifestPath -Raw | ConvertFrom-Json
        $manifest.SchemaVersion | Should -Be '1.0'
        $manifest.Readiness | Should -Be 'ReviewRequired'
        $manifest.Installer.ProductName | Should -Be 'Obsidian Fixture'
        $manifest.Installer.ProductCode | Should -BeNullOrEmpty
        $manifest.PackageSpec.InstallCommand.Executable | Should -Be 'squirrel.exe'
        @($manifest.PackageSpec.InstallCommand.ArgumentList) | Should -Be @('--silent')
        $manifest.PackageSpec.SelectedContext | Should -Be 'User'
        $manifest.PackageSpec.RequiresLogonWhenUserContext | Should -BeTrue
        $manifest.PackageSpec.UninstallCommand.Executable | Should -Be '%LOCALAPPDATA%\Obsidian Fixture\uninstall.exe'
        ($manifest.PackageSpec.DetectionSpec[0].Path -replace '\\','/') | Should -Be '%LOCALAPPDATA%/Obsidian Fixture'
        $manifest.PackageSpec.DetectionSpec[0].FileName | Should -Be 'Obsidian.exe'

        $installEvidence = @($manifest.Installer.Evidence | Where-Object Field -eq 'InstallCommand')
        $installEvidence[0].Source | Should -Be 'Inferred'
        $installEvidence[0].Value.ArgumentList | Should -Be @('--silent')
        @($manifest.Installer.Evidence | Where-Object { $_.Field -eq 'ProductCode' }) | Should -HaveCount 0
        ($manifest.Installer.Evidence | Where-Object Field -eq 'InstallLocation').Source | Should -Be 'DiscoveryJson'
        ($manifest.Installer.Evidence | Where-Object Field -eq 'SelectedContext').Source | Should -Be 'DiscoveryJson'
        ($manifest.Installer.Evidence | Where-Object Field -eq 'UninstallCommand').Source | Should -Be 'DiscoveryJson'
        ($manifest.Installer.Evidence | Where-Object Field -eq 'DetectionTarget').Source | Should -Be 'DiscoveryJson'
        ($manifest.Installer.Evidence | Where-Object Field -eq 'InstallLocation').Notes | Should -Match 'Registry'

        $mecm = New-MecmDeploymentSpec -ManifestPath $scaffold.ManifestPath -ContentSourcePath 'Content/Obsidian'
        $mecm.SpecPath | Should -Exist
        $mecmSpec = Get-Content -LiteralPath $mecm.SpecPath -Raw | ConvertFrom-Json
        $mecmSpec.DeploymentType[0].InstallCommand | Should -Be 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent -AllowRebootPassThru'
        $mecmSpec.DeploymentType[0].UserExperience.InstallBehavior | Should -Be 'InstallForUser'
        $mecmSpec.DeploymentType[0].UserExperience.LogonRequirement | Should -Be 'OnlyWhenUserLoggedOn'
        ($mecmSpec.Findings | Where-Object Code -eq 'MSI_PRODUCT_CODE_REQUIRED') | Should -BeNullOrEmpty

        $psadt = New-PSADTPackage -ManifestPath $scaffold.ManifestPath
        $psadt.DeploymentScriptPath | Should -Exist
        $content = Get-Content -LiteralPath $psadt.DeploymentScriptPath -Raw
        $content | Should -Match "Start-ADTProcess -FilePath 'squirrel.exe' -ArgumentList @\('--silent'\)"
        $content | Should -Not -Match 'msiexec'
    }
    }
}

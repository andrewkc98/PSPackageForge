<#
    First PSADT slice: pure rendering into the stable PSAppDeployToolkit 4.0.6 frontend
    contract, exact local module resolution, and the manifest-driven public write boundary.
#>

$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {

    BeforeAll {
        $script:ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:SevenZipManifest = Get-Content `
            -LiteralPath (Join-Path $script:ModuleRoot 'Examples\SevenZip\PackageManifest.json') `
            -Raw | ConvertFrom-Json

        # These assignments and markers are the v4.0.6 frontend seam PSPackageForge uses.
        # The native toolkit owns everything else in Invoke-AppDeployToolkit.ps1.
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
            param(
                [string] $Destination,
                [string] $Name,
                [int] $Version,
                [switch] $PassThru
            )

            if ($Version -ne 4) { throw 'The test template command only accepts v4.' }
            $packagePath = Join-Path -Path $Destination -ChildPath $Name
            [void] (New-Item -ItemType Directory -Path $packagePath -Force)
            [void] (New-Item -ItemType Directory -Path (Join-Path $packagePath 'Files') -Force)
            Set-Content -LiteralPath (Join-Path $packagePath 'Invoke-AppDeployToolkit.ps1') `
                -Value $script:NativeFrontend -Encoding UTF8
            if ($PassThru) { Get-Item -LiteralPath $packagePath }
        }
    }

    Describe 'PSADT pure renderer' {

        It 'maps the committed manifest into the pinned v4 frontend without parsing command strings' {
            $plan = ConvertTo-PSADTRenderPlan -Manifest $script:SevenZipManifest
            $content = ConvertTo-PSADTTemplateContent `
                -TemplateContent $script:NativeFrontend -RenderPlan $plan

            $content | Should -Match "AppVendor = 'Igor Pavlov'"
            $content | Should -Match "AppName = '7-Zip 26.02 \(x64 edition\)'"
            $content | Should -Match "AppVersion = '26.02.00.0'"
            $content | Should -Match "AppArch = 'x64'"
            $content | Should -Match 'AppSuccessExitCodes = @\(0, 1707\)'
            $content | Should -Match 'AppRebootExitCodes = @\(1641, 3010\)'
            $content | Should -Match "Start-ADTProcess -FilePath 'msiexec.exe' -ArgumentList @\('/i', '7z2602-x64.msi', '/qn'\)"
            $content | Should -Match '-WorkingDirectory \$adtSession\.DirFiles'
            $content | Should -Match "Start-ADTProcess -FilePath 'msiexec.exe' -ArgumentList @\('/x', '\{23170F69-40C1-2702-2602-000001000000\}', '/qn'\)"
        }

        It 'single-quotes installer-controlled values as data' {
            ConvertTo-PSADTPowerShellStringLiteral -Value "O'Brien's App" |
                Should -Be "'O''Brien''s App'"
        }

        It 'fails closed when the pinned frontend marker contract is absent' {
            $plan = ConvertTo-PSADTRenderPlan -Manifest $script:SevenZipManifest
            $badTemplate = $script:NativeFrontend.Replace('## <Perform Installation tasks here>', '## changed upstream')

            { ConvertTo-PSADTTemplateContent -TemplateContent $badTemplate -RenderPlan $plan } |
                Should -Throw '*Perform Installation tasks here*'
        }

        It 'rejects an expected exit code that is not modeled as success' {
            $manifest = $script:SevenZipManifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $manifest.PackageSpec.InstallCommand.ExpectedExitCodes = @(0, 1618)

            { ConvertTo-PSADTRenderPlan -Manifest $manifest } |
                Should -Throw "*1618*classified as 'Retry'*"
        }
    }

    Describe 'Resolve-PSADTTemplateCommand' {

        It 'fails clearly and never downloads when the exact pinned version is unavailable' {
            Mock Get-Module { @() } -ParameterFilter { $ListAvailable -and $Name -eq 'PSAppDeployToolkit' }

            { Resolve-PSADTTemplateCommand -RequiredVersion ([Version] '4.0.6') } |
                Should -Throw '*4.0.6*never downloads tooling automatically*'
        }

        It 'rejects an explicitly supplied module manifest at another version' {
            $modulePath = Join-Path $TestDrive 'PSAppDeployToolkit.psd1'
            Set-Content -LiteralPath $modulePath -Encoding UTF8 -Value "@{ ModuleVersion = '4.1.0' }"

            { Resolve-PSADTTemplateCommand -RequiredVersion ([Version] '4.0.6') -ModulePath $modulePath } |
                Should -Throw '*provides version 4.1.0*requires exactly 4.0.6*'
        }
    }

    Describe 'New-PSADTPackage' {

        BeforeEach {
            $script:ScaffoldPath = Join-Path $TestDrive 'scaffold'
            [void] (New-Item -ItemType Directory -Path $script:ScaffoldPath -Force)
            $script:StagedInstallerPath = Join-Path $script:ScaffoldPath 'setup.exe'
            Set-Content -LiteralPath $script:StagedInstallerPath -Value 'synthetic installer bytes' -NoNewline
            $hash = (Get-FileHash -LiteralPath $script:StagedInstallerPath -Algorithm SHA256).Hash

            $manifestObject = [ordered] @{
                SchemaVersion = '1.0'
                Generator = [ordered] @{
                    Name = 'PSPackageForge'
                    Version = '0.1.0'
                    RequiredPSADTVersion = '4.0.6'
                }
                Installer = [ordered] @{
                    Path = 'setup.exe'
                    FileName = 'setup.exe'
                    SHA256 = $hash
                    ProductName = "O'Brien App"
                    Manufacturer = "O'Brien Software"
                    ProductVersionRaw = '1.2.3'
                    Architecture = 'x64'
                }
                PackageSpec = [ordered] @{
                    InstallCommand = [ordered] @{
                        Executable = 'setup.exe'
                        ArgumentList = @('/S', "OWNER=O'Brien")
                        ExpectedExitCodes = @(0, 3010)
                    }
                    UninstallCommand = [ordered] @{
                        Executable = 'C:\Program Files\OBrien\uninstall.exe'
                        ArgumentList = @('/S')
                        ExpectedExitCodes = @(0)
                    }
                    ReturnCodeMap = @(
                        [ordered] @{ Code = 0; Meaning = 'Success'; Classification = 'Success' },
                        [ordered] @{ Code = 3010; Meaning = 'Reboot required'; Classification = 'SuccessRebootRequired' }
                    )
                }
                Readiness = 'ReviewRequired'
            }
            $script:ManifestPath = Join-Path $script:ScaffoldPath 'PackageManifest.json'
            $manifestObject | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8

            Mock Resolve-PSADTTemplateCommand { $script:FakeTemplateCommand }
        }

        It 'creates the default Package root, renders commands, and copies the hash-checked installer' {
            $result = New-PSADTPackage -ManifestPath $script:ManifestPath

            $result.PackagePath | Should -Be (Join-Path $script:ScaffoldPath 'Package')
            $result.PSADTVersion | Should -Be '4.0.6'
            $result.DeploymentScriptPath | Should -Exist
            $result.InstallerPath | Should -Exist
            (Get-FileHash -LiteralPath $result.InstallerPath -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath $script:StagedInstallerPath -Algorithm SHA256).Hash

            $content = Get-Content -LiteralPath $result.DeploymentScriptPath -Raw
            $content | Should -Match "AppName = 'O''Brien App'"
            $content | Should -Match "-ArgumentList @\('/S', 'OWNER=O''Brien'\)"
            $installLine = @($content -split '\r?\n' | Where-Object { $_ -like "*FilePath 'setup.exe'*" })
            $uninstallLine = @($content -split '\r?\n' | Where-Object { $_ -like "*FilePath 'C:\Program Files\OBrien\uninstall.exe'*" })
            $installLine[0] | Should -Match '-RebootExitCodes @\(3010\)'
            $uninstallLine[0] | Should -Not -Match '-RebootExitCodes'
            $uninstallLine[0] | Should -Not -Match '@\(\)'
            Should -Invoke Resolve-PSADTTemplateCommand -Times 1 -Exactly -ParameterFilter {
                $RequiredVersion -eq [Version] '4.0.6' -and [string]::IsNullOrWhiteSpace($ModulePath)
            }
        }

        It 'does not resolve PSADT or write output under WhatIf' {
            $outputPath = Join-Path $TestDrive 'whatif-package'

            New-PSADTPackage -ManifestPath $script:ManifestPath -OutputPath $outputPath -WhatIf

            $outputPath | Should -Not -Exist
            Should -Invoke Resolve-PSADTTemplateCommand -Times 0 -Exactly
        }

        It 'refuses a non-empty output directory without overwriting it' {
            $outputPath = Join-Path $TestDrive 'occupied'
            [void] (New-Item -ItemType Directory -Path $outputPath)
            $sentinelPath = Join-Path $outputPath 'keep.txt'
            Set-Content -LiteralPath $sentinelPath -Value 'keep me'

            { New-PSADTPackage -ManifestPath $script:ManifestPath -OutputPath $outputPath } |
                Should -Throw '*already exists and is not empty*'
            Get-Content -LiteralPath $sentinelPath | Should -Be 'keep me'
            Should -Invoke Resolve-PSADTTemplateCommand -Times 0 -Exactly
        }

        It 'rejects NeedsInput before resolving PSADT or creating output' {
            $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
            $manifest.Readiness = 'NeedsInput'
            $manifest | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8

            { New-PSADTPackage -ManifestPath $script:ManifestPath } |
                Should -Throw "*readiness is 'NeedsInput'*"
            Should -Invoke Resolve-PSADTTemplateCommand -Times 0 -Exactly
        }

        It 'rejects a staged installer whose bytes no longer match the manifest' {
            Set-Content -LiteralPath $script:StagedInstallerPath -Value 'changed bytes' -NoNewline

            { New-PSADTPackage -ManifestPath $script:ManifestPath } |
                Should -Throw '*Staged installer hash mismatch*'
            Should -Invoke Resolve-PSADTTemplateCommand -Times 0 -Exactly
        }

        It 'requires the installer to be the staged file beside the manifest' {
            $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
            $manifest.Installer.Path = '..\setup.exe'
            $manifest | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8

            { New-PSADTPackage -ManifestPath $script:ManifestPath } |
                Should -Throw '*same staged file directly beside PackageManifest.json*'
            Should -Invoke Resolve-PSADTTemplateCommand -Times 0 -Exactly
        }
    }
}

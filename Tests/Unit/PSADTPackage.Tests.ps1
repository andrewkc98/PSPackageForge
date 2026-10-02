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
            [void] (New-Item -ItemType Directory -Path (Join-Path $packagePath 'Config') -Force)
            [void] (New-Item -ItemType Directory -Path (Join-Path $packagePath 'PSAppDeployToolkit') -Force)
            Set-Content -LiteralPath (Join-Path $packagePath 'Invoke-AppDeployToolkit.ps1') `
                -Value $script:NativeFrontend -Encoding UTF8
            $launcher = [byte[]]::new(68)
            $launcher[0] = 0x4D; $launcher[1] = 0x5A; $launcher[0x3C] = 64
            $launcher[64] = 0x50; $launcher[65] = 0x45
            [System.IO.File]::WriteAllBytes((Join-Path $packagePath 'Invoke-AppDeployToolkit.exe'), $launcher)
            Set-Content -LiteralPath (Join-Path $packagePath 'Config/config.psd1') -Encoding UTF8 -Value $script:TemplateConfigContent
            Set-Content -LiteralPath (Join-Path $packagePath 'PSAppDeployToolkit/PSAppDeployToolkit.psd1') -Encoding UTF8 -Value "@{ ModuleVersion = '$($script:TemplateToolkitVersion)'; RootModule = 'PSAppDeployToolkit.psm1' }"
            Set-Content -LiteralPath (Join-Path $packagePath 'PSAppDeployToolkit/PSAppDeployToolkit.psm1') -Encoding UTF8 -Value 'function Test-Toolkit {}'
            if ($PassThru) { [pscustomobject] @{ FullName = $packagePath } }
        }

        $script:TemplateConfigContent = @'
@{ Toolkit = @{ RequireAdmin = $true; LogPathNoAdminRights = 'old' }; MSI = @{ LogPathNoAdminRights = 'old' } }
'@
        $script:TemplateToolkitVersion = '4.0.6'
        $script:ValidFakeTemplateCommand = $script:FakeTemplateCommand
    }

    Describe 'PSADT pure renderer' {

        It 'maps the committed manifest into the pinned v4 frontend without parsing command strings' {
            $manifest = $script:SevenZipManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            $manifest.Installer | Add-Member -MemberType NoteProperty -Name ApplicationArchitecture -Value 'x64' -Force
            $manifest.Installer | Add-Member -MemberType NoteProperty -Name ResolvedEvidence -Value @(
                [pscustomobject]@{ Field = 'ApplicationArchitecture'; Value = 'x64'; Confidence = 'High' }
            ) -Force
            $plan = ConvertTo-PSADTRenderPlan -Manifest $manifest
            $content = ConvertTo-PSADTTemplateContent `
                -TemplateContent $script:NativeFrontend -RenderPlan $plan

            $content | Should -Match "AppVendor = 'Igor Pavlov'"
            $content | Should -Match "AppName = '7-Zip 26.02 \(x64 edition\)'"
            $content | Should -Match "AppVersion = '26.02.00.0'"
            $content | Should -Match "AppArch = 'x64'"
            $content | Should -Match 'AppSuccessExitCodes = @\(0, 1707\)'
            $content | Should -Match 'AppRebootExitCodes = @\(1641, 3010\)'
            $content | Should -Match "Invoke-PSPFStartADTProcess -Executable 'msiexec.exe'"
            $content | Should -Match "-ArgumentList @\('/i'"
            ([regex]::Matches($content, "Invoke-PSPFStartADTProcess -Executable 'msiexec.exe'")).Count | Should -Be 2
            $content | Should -Match 'function Invoke-PSPFStartADTProcess'
            ([regex]::Matches($content, 'function Invoke-PSPFStartADTProcess')).Count | Should -Be 1
            $content | Should -Match '\[Environment\]::ExpandEnvironmentVariables'
        }

        It 'renders application architecture only for high-confidence evidence' {
            foreach ($case in @(
                @{ Architecture = 'x64'; Confidence = 'High'; Expected = "AppArch = 'x64'" },
                @{ Architecture = 'x64'; Confidence = 'Medium'; Expected = "AppArch = 'x64'" },
                @{ Architecture = 'x64'; Confidence = 'Low';  Expected = "AppArch = ''" },
                @{ Architecture = 'Unknown'; Confidence = 'High'; Expected = "AppArch = ''" }
            )) {
                $manifest = $script:SevenZipManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
                $manifest.Installer | Add-Member -MemberType NoteProperty -Name ApplicationArchitecture -Value $case.Architecture -Force
                $manifest.Installer | Add-Member -MemberType NoteProperty -Name ResolvedEvidence -Value @(
                    [pscustomobject]@{ Field = 'ApplicationArchitecture'; Value = $case.Architecture; Confidence = $case.Confidence }
                ) -Force
                (ConvertTo-PSADTTemplateContent -TemplateContent $script:NativeFrontend -RenderPlan (ConvertTo-PSADTRenderPlan -Manifest $manifest)) |
                    Should -Match $case.Expected
            }
        }

        It 'single-quotes installer-controlled values as data' {
            ConvertTo-PSADTPowerShellStringLiteral -Value "O'Brien's App" |
                Should -Be "'O''Brien''s App'"
        }

        It 'keeps empty operation classifications separate from session defaults' {
            $returnCodeMap = @(
                [pscustomobject] @{ Code = 0; Classification = 'Success' },
                [pscustomobject] @{ Code = 3010; Classification = 'SuccessRebootRequired' }
            )
            $installData = Get-PSADTCommandRenderData -Operation Install `
                -Command ([pscustomobject] @{ Executable = 'install.exe'; ExpectedExitCodes = @(0, 3010) }) `
                -ReturnCodeMap $returnCodeMap
            $uninstallData = Get-PSADTCommandRenderData -Operation Uninstall `
                -Command ([pscustomobject] @{ Executable = 'uninstall.exe'; ExpectedExitCodes = @(0) }) `
                -ReturnCodeMap $returnCodeMap

            $installStatement = ConvertTo-PSADTProcessStatement -CommandData $installData
            $uninstallStatement = ConvertTo-PSADTProcessStatement -CommandData $uninstallData

            $installStatement | Should -Match '-SuccessExitCodes @\(0\)'
            $installStatement | Should -Match '-RebootExitCodes @\(3010\)'
            $uninstallStatement | Should -Match '-SuccessExitCodes @\(0\)'
            $uninstallStatement | Should -Match '-RebootExitCodes @\(-2147483648\)'
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

        It 'fails closed when the deployment helper marker is duplicated' {
            $plan = ConvertTo-PSADTRenderPlan -Manifest $script:SevenZipManifest
            $badTemplate = $script:NativeFrontend -replace 'function Install-ADTDeployment', "function Install-ADTDeployment`nfunction Install-ADTDeployment"

            { ConvertTo-PSADTTemplateContent -TemplateContent $badTemplate -RenderPlan $plan } |
                Should -Throw '*function Install-ADTDeployment*'
        }
    }

    Describe 'ConvertTo-PSADTConfigContent' {

        BeforeAll {
            $script:ConfigContent = @'
@{
    Unrelated = @{ LogPathNoAdminRights = 'leave me' }
    Toolkit = @{
        RequireAdmin = $true
        LogPathNoAdminRights = 'old toolkit path'
        RegPathNoAdminRights = 'leave this too'
        TempPathNoAdminRights = 'leave this too'
    }
    MSI = @{
        LogPathNoAdminRights = 'old msi path'
    }
}
'@
        }

        It 'patches only the user-context target values and reparses as a config document' {
            $result = ConvertTo-PSADTConfigContent -ConfigContent $script:ConfigContent -SelectedContext User

            $result | Should -Match 'RequireAdmin = \$false'
            $result | Should -Match "Unrelated = @{ LogPathNoAdminRights = 'leave me' }"
            $result | Should -Match "RegPathNoAdminRights = 'leave this too'"
            $result | Should -Match "TempPathNoAdminRights = 'leave this too'"

            $path = Join-Path $TestDrive 'config.psd1'
            Set-Content -LiteralPath $path -Value $result -Encoding UTF8 -NoNewline
            $document = Import-PowerShellDataFile -LiteralPath $path
            $document.Toolkit.RequireAdmin | Should -BeFalse
            $document.Toolkit.LogPathNoAdminRights | Should -Be '$envLocalAppData\Logs\Software'
            $document.MSI.LogPathNoAdminRights | Should -Be '$envLocalAppData\Logs\Software'
            $document.Unrelated.LogPathNoAdminRights | Should -Be 'leave me'
            $document.Toolkit.RegPathNoAdminRights | Should -Be 'leave this too'
            $document.Toolkit.TempPathNoAdminRights | Should -Be 'leave this too'

            $tokens = $null
            $errors = $null
            $parsed = [System.Management.Automation.Language.Parser]::ParseInput($result, [ref] $tokens, [ref] $errors)
            @($errors).Count | Should -Be 0
            $parsed.EndBlock.Statements.Count | Should -Be 1
            $result | Should -Not -Match '\$envLocalAppData\\Logs\\Software"'
        }

        It 'returns System content byte-identically and requires literal true' {
            $result = ConvertTo-PSADTConfigContent -ConfigContent $script:ConfigContent -SelectedContext System
            $result | Should -BeExactly $script:ConfigContent

            $bad = $script:ConfigContent.Replace('RequireAdmin = $true', 'RequireAdmin = $false')
            { ConvertTo-PSADTConfigContent -ConfigContent $bad -SelectedContext System } |
                Should -Throw '*literal $true*'
        }

        It 'accepts quoted literal section and target keys' {
            $content = @'
@{ 'Toolkit' = @{ 'RequireAdmin' = $true; 'LogPathNoAdminRights' = 'x' }; "MSI" = @{ "LogPathNoAdminRights" = 'y' } }
'@
            { ConvertTo-PSADTConfigContent -ConfigContent $content -SelectedContext User } |
                Should -Not -Throw
        }

        It 'fails closed for malformed, duplicate, missing, and wrongly nested targets' {
            $cases = @(
                '@{ Toolkit = @{ RequireAdmin = $true; LogPathNoAdminRights = ''x'' }; MSI = @{ LogPathNoAdminRights = ''y'' }'
                '@{ Toolkit = @{ RequireAdmin = $true; RequireAdmin = $true; LogPathNoAdminRights = ''x'' }; MSI = @{ LogPathNoAdminRights = ''y'' } }'
                '@{ Toolkit = @{ RequireAdmin = $true }; MSI = @{ LogPathNoAdminRights = ''y'' } }'
                '@{ Toolkit = @{ RequireAdmin = $true; LogPathNoAdminRights = ''x'' }; MSI = @{ Nested = @{ LogPathNoAdminRights = ''y'' } } }'
                '@{ Toolkit = @{ RequireAdmin = $true; LogPathNoAdminRights = @{} }; MSI = @{ LogPathNoAdminRights = ''y'' } }'
                '@{ Toolkit = @{ RequireAdmin = $true; LogPathNoAdminRights = ''x'' }; MSI = @{ LogPathNoAdminRights = ''y'' } }; @{}'
                '@{ Toolkit = @{ RequireAdmin = $true; LogPathNoAdminRights = ''x'' }; Toolkit = @{}; MSI = @{ LogPathNoAdminRights = ''y'' } }'
                '@{ Toolkit = @{ RequireAdmin = (Get-Value); LogPathNoAdminRights = ''x'' }; MSI = @{ LogPathNoAdminRights = ''y'' } }'
                'param(); @{ Toolkit = @{ RequireAdmin = $true; LogPathNoAdminRights = ''x'' }; MSI = @{ LogPathNoAdminRights = ''y'' } }'
            )

            foreach ($case in $cases) {
                { ConvertTo-PSADTConfigContent -ConfigContent $case -SelectedContext User } |
                    Should -Throw
            }
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
            $script:FakeTemplateCommand = $script:ValidFakeTemplateCommand
            $script:TemplateConfigContent = @'
@{ Toolkit = @{ RequireAdmin = $true; LogPathNoAdminRights = 'old' }; MSI = @{ LogPathNoAdminRights = 'old' } }
'@
            $script:TemplateToolkitVersion = '4.0.6'
            $script:ScaffoldPath = Join-Path $TestDrive 'scaffold'
            if (Test-Path -LiteralPath $script:ScaffoldPath) {
                Remove-Item -LiteralPath $script:ScaffoldPath -Recurse -Force
            }
            [void] (New-Item -ItemType Directory -Path $script:ScaffoldPath -Force)
            $script:StagedInstallerPath = Join-Path $script:ScaffoldPath 'setup.exe'
            Set-Content -LiteralPath $script:StagedInstallerPath -Value 'synthetic installer bytes' -NoNewline
            $hash = (Get-FileHash -LiteralPath $script:StagedInstallerPath -Algorithm SHA256).Hash

            $manifestObject = $script:SevenZipManifest | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            $manifestObject.Installer.Path = 'setup.exe'
            $manifestObject.Installer.FileName = 'setup.exe'
            $manifestObject.Installer.SHA256 = $hash
            $manifestObject.Installer.ProductName = "O'Brien App"
            $manifestObject.Installer.Manufacturer = "O'Brien Software"
            $manifestObject.Installer.ProductVersionRaw = '1.2.3'
            $manifestObject.PackageSpec.InstallCommand.Executable = 'setup.exe'
            $manifestObject.PackageSpec.InstallCommand.ArgumentList = @('/S', "OWNER=O'Brien")
            $manifestObject.PackageSpec.UninstallCommand.Executable = 'C:\Program Files\OBrien\uninstall.exe'
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
            $installLine = @($content -split '\r?\n' | Where-Object { $_ -like "*Invoke-PSPFStartADTProcess -Executable 'setup.exe'*" })
            $uninstallLine = @($content -split '\r?\n' | Where-Object { $_ -like "*Invoke-PSPFStartADTProcess -Executable 'C:\Program Files\OBrien\uninstall.exe'*" })
            $installLine.Count | Should -Be 1
            $uninstallLine.Count | Should -Be 1
            $installLine[0] | Should -Match '-SuccessExitCodes @\(0, 1707\)'
            $installLine[0] | Should -Match '-RebootExitCodes @\(3010, 1641\)'
            $uninstallLine[0] | Should -Match '-SuccessExitCodes @\(0, 1707\)'
            $uninstallLine[0] | Should -Match '-RebootExitCodes @\(3010, 1641\)'
            $uninstallLine[0] | Should -Not -Match '@\(\)'
            $content | Should -Not -Match 'App(?:Success|Reboot)ExitCodes = @\([^)]*-2147483648'
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
                Should -Throw "*readiness is 'NeedsInput'*ReviewRequired*"
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
                Should -Throw '*must exactly match one direct child filename*'
            Should -Invoke Resolve-PSADTTemplateCommand -Times 0 -Exactly
        }

        It 'removes its staging directory when frontend rendering fails' {
            Mock ConvertTo-PSADTTemplateContent { throw 'frontend stage failed' }
            { New-PSADTPackage -ManifestPath $script:ManifestPath } | Should -Throw '*frontend stage failed*'
            (Get-ChildItem -LiteralPath $script:ScaffoldPath -Directory -Force | Where-Object Name -Like '.psforge-*') | Should -BeNullOrEmpty
            (Join-Path $script:ScaffoldPath 'Package') | Should -Not -Exist
        }

        It 'removes a partial staging directory when the template throws after creating it' {
            $script:FakeTemplateCommand = {
                param([string] $Destination, [string] $Name, [int] $Version, [switch] $PassThru)
                $script:TemplateInvocation = @{ Version = $Version; PassThru = $PassThru }
                [void] (New-Item -ItemType Directory -Path (Join-Path $Destination $Name) -Force)
                throw 'template failed after creation'
            }
            { New-PSADTPackage -ManifestPath $script:ManifestPath } | Should -Throw '*template failed after creation*'
            $script:TemplateInvocation.Version | Should -Be 4
            $script:TemplateInvocation.PassThru | Should -BeTrue
            (Get-ChildItem -LiteralPath $script:ScaffoldPath -Directory -Force | Where-Object Name -Like '.psforge-*') | Should -BeNullOrEmpty
            (Join-Path $script:ScaffoldPath 'Package') | Should -Not -Exist
        }

        It 'removes its staging directory when context configuration is invalid' {
            $script:TemplateConfigContent = '@{ Toolkit = @{ RequireAdmin = $false }; MSI = @{} }'
            { New-PSADTPackage -ManifestPath $script:ManifestPath } | Should -Throw '*missing*LogPathNoAdminRights*'
            (Get-ChildItem -LiteralPath $script:ScaffoldPath -Directory -Force | Where-Object Name -Like '.psforge-*') | Should -BeNullOrEmpty
            (Join-Path $script:ScaffoldPath 'Package') | Should -Not -Exist
        }

        It 'rejects a bundled toolkit with the wrong version and cleans staging' {
            $script:TemplateToolkitVersion = '4.0.7'
            { New-PSADTPackage -ManifestPath $script:ManifestPath } | Should -Throw '*does not match the required version*'
            (Get-ChildItem -LiteralPath $script:ScaffoldPath -Directory -Force | Where-Object Name -Like '.psforge-*') | Should -BeNullOrEmpty
            (Join-Path $script:ScaffoldPath 'Package') | Should -Not -Exist
        }

        It 'cleans staging when installer copy fails' {
            Mock Copy-Item { throw 'payload stage failed' }
            { New-PSADTPackage -ManifestPath $script:ManifestPath } | Should -Throw '*payload stage failed*'
            (Get-ChildItem -LiteralPath $script:ScaffoldPath -Directory -Force | Where-Object Name -Like '.psforge-*') | Should -BeNullOrEmpty
            (Join-Path $script:ScaffoldPath 'Package') | Should -Not -Exist
        }

        It 'cleans staging when receipt creation fails' {
            Mock Write-PackageForgeReceipt { throw 'receipt stage failed' }
            { New-PSADTPackage -ManifestPath $script:ManifestPath } | Should -Throw '*receipt stage failed*'
            (Get-ChildItem -LiteralPath $script:ScaffoldPath -Directory -Force | Where-Object Name -Like '.psforge-*') | Should -BeNullOrEmpty
            (Join-Path $script:ScaffoldPath 'Package') | Should -Not -Exist
        }

        It 'cleans staging when receipt-backed package validation fails' {
            Mock Test-PackageForgePackage { throw 'package validation failed' }
            { New-PSADTPackage -ManifestPath $script:ManifestPath } | Should -Throw '*package validation failed*'
            (Get-ChildItem -LiteralPath $script:ScaffoldPath -Directory -Force | Where-Object Name -Like '.psforge-*') | Should -BeNullOrEmpty
            (Join-Path $script:ScaffoldPath 'Package') | Should -Not -Exist
        }

        It 'replaces a verified empty destination by atomic publication' {
            $outputPath = Join-Path $script:ScaffoldPath 'empty-package'
            [void] (New-Item -ItemType Directory -Path $outputPath)
            $result = New-PSADTPackage -ManifestPath $script:ManifestPath -OutputPath $outputPath
            $result.PackagePath | Should -Be $outputPath
            (Join-Path $outputPath 'PSPackageForgeReceipt.json') | Should -Exist
            (Get-ChildItem -LiteralPath $script:ScaffoldPath -Directory -Force | Where-Object Name -Like '.psforge-*') | Should -BeNullOrEmpty
        }

        It 'patches the generated config for the manifest selected user context' {
            $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
            $manifest.PackageSpec.SelectedContext = 'User'
            $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8

            $result = New-PSADTPackage -ManifestPath $script:ManifestPath
            $configPath = Join-Path $result.PackagePath 'Config/config.psd1'
            $config = Import-PowerShellDataFile -LiteralPath $configPath
            $config.Toolkit.RequireAdmin | Should -BeFalse
            $config.Toolkit.LogPathNoAdminRights | Should -Be '$envLocalAppData\Logs\Software'
            $config.MSI.LogPathNoAdminRights | Should -Be '$envLocalAppData\Logs\Software'
        }
    }
}

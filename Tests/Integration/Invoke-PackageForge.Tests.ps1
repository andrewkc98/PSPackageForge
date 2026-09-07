$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {
    Describe 'Invoke-PackageForge discover dispatcher' {
        BeforeAll {
            function Get-TestDiscoveryResult {
                param(
                    [string] $DisplayNameLike,
                    [string] $OutputPath
                )

                [PSCustomObject] @{
                    PSTypeName      = 'PSPackageForge.InstalledAppDiscoveryResult'
                    SchemaVersion  = '1.0'
                    GeneratedAtUtc = '2026-01-01T00:00:00.0000000Z'
                    Query           = [ordered] @{ DisplayNameLike = $DisplayNameLike }
                    Matches         = @(
                        [PSCustomObject] @{
                            MatchId     = 'abc123'
                            DisplayName = 'Acme App'
                        }
                    )
                    Findings        = @(
                        [PSCustomObject] @{
                            Severity = 'Info'
                            Code     = 'TEST_FINDING'
                            Message  = 'test finding'
                        }
                    )
                    DiscoveryPath   = $OutputPath
                    Provenance      = [ordered] @{ Source = 'mock' }
                }
            }
        }

        BeforeEach {
            Mock Get-InstalledAppInfo {
                param($DisplayNameLike, $OutputPath)
                Get-TestDiscoveryResult -DisplayNameLike $DisplayNameLike -OutputPath $OutputPath
            }
        }

        It 'uses the exact flat public parameter contract' {
            $command = Get-Command Invoke-PackageForge

            $command.Parameters['Action'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] })[0].Position | Should -Be 0
            $command.Parameters['Action'].Attributes.Where({ $_ -is [System.Management.Automation.ValidateSetAttribute] })[0].ValidValues | Should -Be @('discover', 'scaffold', 'pack')
            $command.Parameters['Path'].Aliases | Should -Be @('InstallerPath', 'Installer', 'PackagePath', 'DisplayNameLike')
            $command.Parameters['Path'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] })[0].Position | Should -Be 1
            $command.Parameters['OutputPath'].Aliases | Should -Contain 'Output'
            $command.Parameters['DiscoveryPath'].Aliases | Should -Be @('Discovery', 'DiscoveryData')
            $command.Parameters['DiscoveryMatchId'].Aliases | Should -Contain 'Match'
            $command.Parameters.ContainsKey('DetectionOperator') | Should -BeTrue
            $command.Parameters.ContainsKey('FailOnLowConfidence') | Should -BeTrue
            $command.Parameters.ContainsKey('PSADTModulePath') | Should -BeTrue
            $command.Parameters.ContainsKey('IntuneWinAppUtilPath') | Should -BeTrue
            $command.Parameters.ContainsKey('WhatIf') | Should -BeTrue
        }

        It 'returns exact result fields and preserves primitive result for positional discover' {
            $destination = Join-Path $TestDrive 'Acme.discovery.json'

            $result = Invoke-PackageForge discover 'Acme*' -OutputPath $destination

            $result.PSTypeNames[0] | Should -Be 'PSPackageForge.PackageForgeResult'
            @($result.PSObject.Properties.Name) | Should -Be @(
                'Action', 'Status', 'OutputPath', 'DiscoveryPath', 'ManifestPath', 'DocumentPath',
                'DetectionPath', 'PackagePath', 'IntuneWinPath', 'Readiness', 'Findings', 'Matches', 'SHA256',
                'DiscoveryResult', 'ScaffoldResult', 'PSADTResult', 'IntuneWinResult', 'PSADTDisposition'
            )
            $result.Action | Should -Be 'discover'
            $result.Status | Should -Be 'Completed'
            $result.OutputPath | Should -BeNullOrEmpty
            $result.DiscoveryPath | Should -Be $destination
            $result.ManifestPath | Should -BeNullOrEmpty
            $result.DocumentPath | Should -BeNullOrEmpty
            $result.DetectionPath | Should -BeNullOrEmpty
            $result.PackagePath | Should -BeNullOrEmpty
            $result.IntuneWinPath | Should -BeNullOrEmpty
            $result.Readiness | Should -BeNullOrEmpty
            $result.SHA256 | Should -BeNullOrEmpty
            $result.ScaffoldResult | Should -BeNullOrEmpty
            $result.PSADTResult | Should -BeNullOrEmpty
            $result.IntuneWinResult | Should -BeNullOrEmpty
            $result.PSADTDisposition | Should -Be 'NotApplicable'
            $result.Matches[0].MatchId | Should -Be 'abc123'
            $result.Findings[0].Code | Should -Be 'TEST_FINDING'
            $result.DiscoveryResult.Provenance.Source | Should -Be 'mock'

            Should -Invoke Get-InstalledAppInfo -Times 1 -Exactly -ParameterFilter {
                $DisplayNameLike -eq 'Acme*' -and $OutputPath -eq $destination
            }
        }

        It 'supports long-form action and DisplayNameLike alias with explicit Output alias' {
            $destination = Join-Path $TestDrive 'Long.discovery.json'

            $result = Invoke-PackageForge -Action DISCOVER -DisplayNameLike 'Long App*' -Output $destination

            $result.Action | Should -Be 'discover'
            $result.DiscoveryPath | Should -Be $destination
            $result.OutputPath | Should -BeNullOrEmpty
            Should -Invoke Get-InstalledAppInfo -Times 1 -Exactly -ParameterFilter {
                $DisplayNameLike -eq 'Long App*' -and $OutputPath -eq $destination
            }
        }

        It 'creates only the required explicit destination parent directory' {
            $parent = Join-Path $TestDrive 'one/two'
            $destination = Join-Path $parent 'apps.discovery.json'
            $sibling = Join-Path $TestDrive 'one/other'

            Mock Get-InstalledAppInfo {
                param($DisplayNameLike, $OutputPath)
                $primitiveParent = Split-Path -Path $OutputPath -Parent
                [void] (New-Item -ItemType Directory -Path $primitiveParent -Force)
                Set-Content -LiteralPath $OutputPath -Value '{}' -NoNewline
                Get-TestDiscoveryResult -DisplayNameLike $DisplayNameLike -OutputPath $OutputPath
            }

            $null = Invoke-PackageForge discover 'Apps*' -OutputPath $destination

            Test-Path -LiteralPath $parent | Should -BeTrue
            Test-Path -LiteralPath $sibling | Should -BeFalse
        }

        It 'does not create a parent or JSON when the primitive declines the write' {
            $parent = Join-Path $TestDrive 'declined/parent'
            $destination = Join-Path $parent 'apps.discovery.json'

            Mock Get-InstalledAppInfo {
                param($DisplayNameLike, $OutputPath)
                Get-TestDiscoveryResult -DisplayNameLike $DisplayNameLike -OutputPath $OutputPath
            }

            $result = Invoke-PackageForge discover 'Apps*' -OutputPath $destination

            $result.Status | Should -Be 'Completed'
            Test-Path -LiteralPath $parent | Should -BeFalse
            Test-Path -LiteralPath $destination | Should -BeFalse
            Should -Invoke Get-InstalledAppInfo -Times 1 -Exactly -ParameterFilter {
                $DisplayNameLike -eq 'Apps*' -and $OutputPath -eq $destination
            }
        }

        It 'derives deterministic default output by stripping invalid and wildcard characters' {
            Push-Location $TestDrive
            try {
                $result = Invoke-PackageForge discover 'A<c>m:e"/\|*?[] . '
            }
            finally {
                Pop-Location
            }

            $expected = Join-Path (Join-Path $TestDrive 'Output') 'Acme.discovery.json'
            $result.DiscoveryPath | Should -Be $expected
            Should -Invoke Get-InstalledAppInfo -Times 1 -Exactly -ParameterFilter {
                $DisplayNameLike -eq 'A<c>m:e"/\|*?[] . ' -and $OutputPath -eq $expected
            }
        }

        It 'falls back for empty and reserved default output names' {
            Push-Location $TestDrive
            try {
                $emptyResult = Invoke-PackageForge discover '<>:"/\|*?[]'
                $reservedResult = Invoke-PackageForge discover 'con'
            }
            finally {
                Pop-Location
            }

            $expected = Join-Path (Join-Path $TestDrive 'Output') 'discovery.discovery.json'
            $emptyResult.DiscoveryPath | Should -Be $expected
            $reservedResult.DiscoveryPath | Should -Be $expected
        }

        It 'passes WhatIf through, returns preview data, and writes no JSON at default destination' {
            Push-Location $TestDrive
            try {
                $result = Invoke-PackageForge discover 'Preview*' -WhatIf
            }
            finally {
                Pop-Location
            }

            $expected = Join-Path (Join-Path $TestDrive 'Output') 'Preview.discovery.json'
            $result.Status | Should -Be 'WhatIf'
            $result.OutputPath | Should -BeNullOrEmpty
            $result.DiscoveryPath | Should -Be $expected
            $result.Matches[0].DisplayName | Should -Be 'Acme App'
            Test-Path -LiteralPath $expected | Should -BeFalse
            Should -Invoke Get-InstalledAppInfo -Times 1 -Exactly -ParameterFilter {
                $DisplayNameLike -eq 'Preview*' -and $OutputPath -eq $expected
            }
        }

        It 'rejects missing discover pattern and scaffold or pack only options' {
            { Invoke-PackageForge discover '' } | Should -Throw '*requires a non-empty display-name wildcard pattern*'
            { Invoke-PackageForge discover 'Acme*' -DiscoveryPath 'apps.json' } | Should -Throw '*does not use -DiscoveryPath*'
            { Invoke-PackageForge discover 'Acme*' -DiscoveryMatchId 'abc123' } | Should -Throw '*does not select a match*'
            { Invoke-PackageForge discover 'Acme*' -DetectionOperator Exact } | Should -Throw '*does not use -DetectionOperator*'
            { Invoke-PackageForge discover 'Acme*' -FailOnLowConfidence } | Should -Throw '*does not use -FailOnLowConfidence*'
            { Invoke-PackageForge discover 'Acme*' -PSADTModulePath 'PSADT' } | Should -Throw '*does not use -PSADTModulePath*'
            { Invoke-PackageForge discover 'Acme*' -IntuneWinAppUtilPath 'tool.exe' } | Should -Throw '*does not use -IntuneWinAppUtilPath*'
        }
    }

    Describe 'Invoke-PackageForge scaffold dispatcher' {
        BeforeAll {
            $script:ScaffoldModuleRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
            $script:ScaffoldFixtureRoot = Join-Path -Path $script:ScaffoldModuleRoot -ChildPath (Join-Path -Path 'Tests' -ChildPath 'Fixtures')

            function Get-TestScaffoldShape {
                param(
                    [string] $OutputPath,
                    [string] $ManifestPath,
                    [string] $DocumentPath,
                    [string] $DetectionPath,
                    [string] $Readiness,
                    [string] $FindingCode
                )

                [PSCustomObject] @{
                    PSTypeName      = 'PSPackageForge.ScaffoldResult'
                    InstallerInfo   = [PSCustomObject] @{
                        Path      = (Join-Path $OutputPath 'staged-installer')
                        Findings  = @([PSCustomObject] @{
                            Severity = 'Info'
                            Code     = $FindingCode
                            Message  = 'scaffold finding'
                        })
                    }
                    PackageSpec     = [PSCustomObject] @{ Readiness = $Readiness }
                    ManifestPath    = $ManifestPath
                    DocumentPath    = $DocumentPath
                    DetectionPath   = $DetectionPath
                    InstallerPath   = (Join-Path $OutputPath 'staged-installer')
                    OutputPath      = $OutputPath
                    Readiness       = $Readiness
                    DiscoveryMatchId = $null
                }
            }
        }

        BeforeEach {
            New-Item -ItemType File -Path (Join-Path $TestDrive 'App.msi') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $TestDrive 'discovery.json') -Force | Out-Null
        }

        It 'forwards discovery path, match id, detection operator, and fail-on-low-confidence exactly' {
            Mock New-PackageScaffold {
                $script:ScaffoldCaptured = @{
                    Path                = $Path
                    OutputPath          = $OutputPath
                    DiscoveryData       = $DiscoveryData
                    DiscoveryMatchId    = $DiscoveryMatchId
                    DetectionOperator   = $DetectionOperator
                    FailOnLowConfidence = [bool] $FailOnLowConfidence
                }
                Get-TestScaffoldShape -OutputPath $OutputPath -ManifestPath (Join-Path $OutputPath 'PackageManifest.json') -Readiness 'ReviewRequired' -FindingCode 'SKELETON'
            }

            $appInstaller = Join-Path $TestDrive 'App.msi'
            $discoveryFile = Join-Path $TestDrive 'discovery.json'
            $destination = Join-Path $TestDrive 'explicit-output'
            $null = Invoke-PackageForge scaffold $appInstaller `
                -OutputPath $destination `
                -DiscoveryPath $discoveryFile `
                -Match 'abc123' -DetectionOperator GreaterOrEqual -FailOnLowConfidence

            $script:ScaffoldCaptured['Path'] | Should -Be $appInstaller
            $script:ScaffoldCaptured['OutputPath'] | Should -Be $destination
            $script:ScaffoldCaptured['DiscoveryData'] | Should -Be $discoveryFile
            $script:ScaffoldCaptured['DiscoveryMatchId'] | Should -Be 'abc123'
            $script:ScaffoldCaptured['DetectionOperator'] | Should -Be 'GreaterOrEqual'
            $script:ScaffoldCaptured['FailOnLowConfidence'] | Should -BeTrue
            Should -Invoke New-PackageScaffold -Times 1 -Exactly
        }

        It 'forwards an explicitly false fail-on-low-confidence switch as false' {
            Mock New-PackageScaffold {
                $script:ScaffoldCaptured = @{ FailOnLowConfidence = [bool] $FailOnLowConfidence }
                Get-TestScaffoldShape -OutputPath $OutputPath -ManifestPath (Join-Path $OutputPath 'PackageManifest.json') -Readiness 'ReviewRequired' -FindingCode 'SKELETON'
            }

            Invoke-PackageForge scaffold (Join-Path $TestDrive 'App.msi') -OutputPath (Join-Path $TestDrive 'false-switch') -FailOnLowConfidence:$false

            $script:ScaffoldCaptured['FailOnLowConfidence'] | Should -BeFalse
            Should -Invoke New-PackageScaffold -Times 1 -Exactly
        }

        It 'derives the default output as an Output subdirectory named after the installer base name' {
            Mock New-PackageScaffold {
                Push-Location $TestDrive
                try {
                    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
                } finally { Pop-Location }
                Get-TestScaffoldShape -OutputPath $OutputPath -ManifestPath (Join-Path $OutputPath 'PackageManifest.json') -Readiness 'ReviewRequired' -FindingCode 'SKELETON'
            }

            $appInstaller = Join-Path $TestDrive 'App.msi'
            Push-Location $TestDrive
            try {
                $result = Invoke-PackageForge scaffold $appInstaller
            } finally {
                Pop-Location
            }

            $expected = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $TestDrive 'Output') 'App'))
            $result.OutputPath | Should -Be $expected
            Should -Invoke New-PackageScaffold -Times 1 -Exactly -ParameterFilter { $OutputPath -eq $expected }
        }

        It 'resolves an explicit relative output against the caller working directory' {
            Mock New-PackageScaffold {
                Get-TestScaffoldShape -OutputPath $OutputPath -ManifestPath (Join-Path $OutputPath 'PackageManifest.json') -Readiness 'ReviewRequired' -FindingCode 'SKELETON'
            }

            Push-Location $TestDrive
            try {
                $result = Invoke-PackageForge scaffold 'App.msi' -OutputPath 'custom-output'
            }
            finally {
                Pop-Location
            }

            $expected = [System.IO.Path]::GetFullPath((Join-Path $TestDrive 'custom-output'))
            $result.OutputPath | Should -Be $expected
            Should -Invoke New-PackageScaffold -Times 1 -Exactly -ParameterFilter { $OutputPath -eq $expected }
        }

        It 'refuses a non-empty existing output target before calling the primitive; an empty root is allowed' {
            $appInstaller = Join-Path $TestDrive 'App.msi'
            Mock New-PackageScaffold { Get-TestScaffoldShape -OutputPath $OutputPath -ManifestPath (Join-Path $OutputPath 'PackageManifest.json') -Readiness 'ReviewRequired' -FindingCode 'SKELETON' }
            $occupied = Join-Path $TestDrive 'occupied'
            [void] (New-Item -ItemType Directory -Path $occupied -Force)
            [void] (New-Item -ItemType File -Path (Join-Path $occupied 'leftover.txt') -Force)

            { Invoke-PackageForge scaffold $appInstaller -OutputPath $occupied } |
                Should -Throw '*non-empty*'
            Should -Invoke New-PackageScaffold -Times 0

            $empty = Join-Path $TestDrive 'empty-root'
            [void] (New-Item -ItemType Directory -Path $empty -Force)

            $result = Invoke-PackageForge scaffold $appInstaller -OutputPath $empty
            $result.OutputPath | Should -Be $empty
            Should -Invoke New-PackageScaffold -Times 1 -Exactly -ParameterFilter { $OutputPath -eq $empty }
        }

        It 'validates installer and discovery existence and rejects DiscoveryMatchId without DiscoveryPath' {
            Mock New-PackageScaffold { throw 'New-PackageScaffold must not be called in this test.' }
            $appInstaller = Join-Path $TestDrive 'App.msi'
            { Invoke-PackageForge scaffold 'missing.msi' -OutputPath (Join-Path $TestDrive 'x') } |
                Should -Throw '*requires an existing installer file*'
            { Invoke-PackageForge scaffold $appInstaller -OutputPath (Join-Path $TestDrive 'x') -DiscoveryPath 'missing.json' } |
                Should -Throw '*requires an existing discovery file*'
            { Invoke-PackageForge scaffold $appInstaller -DiscoveryMatchId 'abc123' } |
                Should -Throw '*-DiscoveryMatchId requires -DiscoveryPath*'
            Should -Invoke New-PackageScaffold -Times 0
        }

        It 'rejects pack-only options on scaffold' {
            $appInstaller = Join-Path $TestDrive 'App.msi'
            { Invoke-PackageForge scaffold $appInstaller -PSADTModulePath 'PSADT' } |
                Should -Throw '*does not use -PSADTModulePath*'
            { Invoke-PackageForge scaffold $appInstaller -IntuneWinAppUtilPath 'tool.exe' } |
                Should -Throw '*does not use -IntuneWinAppUtilPath*'
        }

        It 'maps NeedsInput readiness to NeedsInput status, completes otherwise, and keeps Matches and SHA256 null' {
            $appInstaller = Join-Path $TestDrive 'App.msi'
            Mock New-PackageScaffold {
                [PSCustomObject] @{
                    PSTypeName      = 'PSPackageForge.ScaffoldResult'
                    InstallerInfo   = [PSCustomObject] @{
                        Findings = @([PSCustomObject] @{ Severity = 'Warning'; Code = 'MSI_WRAPPER_DETECTED'; Message = 'wrapper' })
                    }
                    ManifestPath    = (Join-Path $OutputPath 'PackageManifest.json')
                    DocumentPath    = (Join-Path $OutputPath 'PackageDocument.md')
                    DetectionPath   = $null
                    InstallerPath   = (Join-Path $OutputPath 'staged-installer')
                    OutputPath      = $OutputPath
                    Readiness       = 'NeedsInput'
                }
            }

            $needsInput = Invoke-PackageForge scaffold $appInstaller -OutputPath (Join-Path $TestDrive 'ni')

            $needsInput.Status | Should -Be 'NeedsInput'
            $needsInput.Readiness | Should -Be 'NeedsInput'
            $needsInput.PackagePath | Should -Be (Join-Path (Join-Path $TestDrive 'ni') 'Package')
            $needsInput.Matches | Should -BeNullOrEmpty
            $needsInput.SHA256 | Should -BeNullOrEmpty
            $needsInput.IntuneWinPath | Should -BeNullOrEmpty
            $needsInput.PSADTDisposition | Should -Be 'NotApplicable'
            $needsInput.ScaffoldResult | Should -Not -BeNullOrEmpty
            $needsInput.Findings[0].Code | Should -Be 'MSI_WRAPPER_DETECTED'
            ($needsInput.PSObject.Properties.Name | Where-Object { $_ -eq 'InstallerPath' }) | Should -BeNullOrEmpty

            Mock New-PackageScaffold {
                Get-TestScaffoldShape -OutputPath $OutputPath -ManifestPath (Join-Path $OutputPath 'PackageManifest.json') -DocumentPath (Join-Path $OutputPath 'PackageDocument.md') -DetectionPath (Join-Path $OutputPath 'Detect-Application.ps1') -Readiness 'ReviewRequired' -FindingCode 'SKELETON'
            }
            $completed = Invoke-PackageForge scaffold $appInstaller -OutputPath (Join-Path $TestDrive 'completed')
            $completed.Status | Should -Be 'Completed'
            $completed.Matches | Should -BeNullOrEmpty
            $completed.SHA256 | Should -BeNullOrEmpty
        }

        It 'keeps the installer path only inside ScaffoldResult under WhatIf and performs no write or primitive call' {
            Mock New-PackageScaffold { throw 'New-PackageScaffold must not be called under WhatIf.' }

            $destination = Join-Path $TestDrive 'whatif'
            $result = Invoke-PackageForge scaffold (Join-Path $TestDrive 'App.msi') -OutputPath $destination -WhatIf

            $result.Status | Should -Be 'WhatIf'
            $result.OutputPath | Should -Be $destination
            $result.ScaffoldResult | Should -BeNullOrEmpty
            $result.ManifestPath | Should -BeNullOrEmpty
            $result.DocumentPath | Should -BeNullOrEmpty
            $result.DetectionPath | Should -BeNullOrEmpty
            $result.Readiness | Should -BeNullOrEmpty
            $result.Findings | Should -BeNullOrEmpty
            $result.Matches | Should -BeNullOrEmpty
            $result.SHA256 | Should -BeNullOrEmpty
            $result.PSADTDisposition | Should -Be 'NotApplicable'
            Test-Path -LiteralPath $destination | Should -BeFalse
            Should -Invoke New-PackageScaffold -Times 0
        }

        It 'delegates native-MSI, recognized-EXE, and wrapper-MSI content behavior to New-PackageScaffold' `
            -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {
            [System.IO.File]::Exists((Join-Path $script:ScaffoldFixtureRoot 'native-clean.msi')) | Should -BeTrue

            $output = Join-Path $TestDrive 'native-scaffold'
            $result = Invoke-PackageForge scaffold (Join-Path $script:ScaffoldFixtureRoot 'native-clean.msi') -OutputPath $output

            $result.Status | Should -Be 'Completed'
            $result.Readiness | Should -Be 'ReviewRequired'
            $result.ManifestPath | Should -Exist
            $result.DetectionPath | Should -Exist
            $result.Matches | Should -BeNullOrEmpty
            $result.SHA256 | Should -BeNullOrEmpty
            $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json
            $manifest.Installer.ProductCode | Should -Not -BeNullOrEmpty
            $wrapperFindings = @($manifest.Findings | Where-Object Code -eq 'MSI_WRAPPER_DETECTED')
            $wrapperFindings | Should -BeNullOrEmpty

            $exe = Join-Path -Path $script:ScaffoldFixtureRoot -ChildPath (Join-Path -Path 'framework-stubs' -ChildPath 'nsis.exe')
            $discovery = Join-Path -Path $script:ScaffoldFixtureRoot -ChildPath (Join-Path -Path 'discovery' -ChildPath 'kicad.discovery.json')
            $exeResult = Invoke-PackageForge scaffold $exe -OutputPath (Join-Path $TestDrive 'exe-scaffold') -DiscoveryPath $discovery
            $exeResult.Status | Should -Be 'Completed'
            $exeResult.Readiness | Should -Be 'ReviewRequired'
            $exeResult.ManifestPath | Should -Exist
            $exeManifest = Get-Content -LiteralPath $exeResult.ManifestPath -Raw | ConvertFrom-Json
            $exeManifest.Installer.ProductName | Should -Be 'KiCad Fixture'

            $wrapper = Join-Path $TestDrive 'wrapper.exe'
            [void] (New-Item -ItemType File -Path $wrapper -Force)
            $wrapperResult = Invoke-PackageForge scaffold $wrapper -OutputPath (Join-Path $TestDrive 'wrapper-scaffold')
            $wrapperResult.Status | Should -Be 'NeedsInput'
            $wrapperResult.Readiness | Should -Be 'NeedsInput'
            $wrapperResult.ManifestPath | Should -Exist
            $wrapperManifest = Get-Content -LiteralPath $wrapperResult.ManifestPath -Raw | ConvertFrom-Json
            @($wrapperManifest.Findings | Where-Object Code -in @('UNINSTALL_COMMAND_UNRESOLVED', 'DETECTION_UNRESOLVED')) | Should -HaveCount 2
        }
    }

    Describe 'Invoke-PackageForge pack dispatcher' {
        BeforeAll {
            $script:PackRootTemplate = Join-Path $TestDrive 'scaffold'

            function Get-PackFixture {
                param(
                    [Parameter(Mandatory)] [string] $Root,
                    [string] $Readiness = 'ReviewRequired',
                    [string] $InstallerFileName = 'setup.exe'
                )

                [void] (New-Item -ItemType Directory -Path $Root -Force)
                $stagedInstaller = Join-Path -Path $Root -ChildPath $InstallerFileName
                Set-Content -LiteralPath $stagedInstaller -Value 'synthetic installer bytes' -NoNewline
                $hash = (Get-FileHash -LiteralPath $stagedInstaller -Algorithm SHA256).Hash

                $manifest = [ordered] @{
                    SchemaVersion = '1.0'
                    Generator     = [ordered] @{ Name = 'PSPackageForge'; RequiredPSADTVersion = '4.0.6' }
                    Installer     = [ordered] @{ Path = $InstallerFileName; FileName = $InstallerFileName; SHA256 = $hash }
                    Readiness     = $Readiness
                }
                $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $Root 'PackageManifest.json') -Encoding UTF8
                return [ordered] @{ Root = $Root; InstallerFileName = $InstallerFileName; Hash = $hash }
            }

            function Get-PackCompletePackage {
                param([Parameter(Mandatory)][object] $Fixture)

                $packageRoot = Join-Path -Path $Fixture.Root -ChildPath 'Package'
                [void] (New-Item -ItemType Directory -Path (Join-Path $packageRoot 'Files') -Force)
                Set-Content -LiteralPath (Join-Path $packageRoot 'Invoke-AppDeployToolkit.exe') -Value 'exe' -NoNewline
                Set-Content -LiteralPath (Join-Path $packageRoot 'Invoke-AppDeployToolkit.ps1') -Value 'script' -NoNewline
                Copy-Item -LiteralPath (Join-Path $Fixture.Root $Fixture.InstallerFileName) `
                    -Destination (Join-Path (Join-Path $packageRoot 'Files') $Fixture.InstallerFileName)
            }

            function Get-PackIntuneBuiltResult {
                param([Parameter(Mandatory)][string] $Root)

                $output = Join-Path $Root 'IntuneWin'
                [void] (New-Item -ItemType Directory -Path $output -Force)
                $artifact = Join-Path $output 'Invoke-AppDeployToolkit.intunewin'
                Set-Content -LiteralPath $artifact -Value 'package' -NoNewline

                [PSCustomObject] @{
                    PSTypeName    = 'PSPackageForge.IntuneWinPackageResult'
                    OutputPath    = (Join-Path $Root 'IntuneWin')
                    Status        = 'Built'
                    IntuneWinPath = $artifact
                    SHA256        = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToUpperInvariant()
                    Findings      = @()
                }
            }

            function Get-PackIntuneInstructionsResult {
                param([Parameter(Mandatory)][string] $Root)

                [PSCustomObject] @{
                    PSTypeName  = 'PSPackageForge.IntuneWinPackageResult'
                    OutputPath  = (Join-Path $Root 'IntuneWin')
                    Status      = 'InstructionsOnly'
                    IntuneWinPath = $null
                    SHA256      = $null
                    Findings    = @([PSCustomObject] @{ Severity = 'Warning'; Code = 'INTUNEWINAPPUTIL_UNAVAILABLE'; Message = 'no tool' })
                }
            }

            function Get-PackPreviewResult {
                [PSCustomObject] @{
                    PSTypeName  = 'PSPackageForge.IntuneWinPackageResult'
                    OutputPath  = (Join-Path $TestDrive 'preview-IntuneWin')
                    Status      = 'InstructionsOnly'
                    IntuneWinPath = $null
                    SHA256      = $null
                    Findings    = @()
                }
            }
        }

        BeforeEach {
            $fixtureRoot = Join-Path $TestDrive 'scaffold'
            [void] (Get-PackFixture -Root $fixtureRoot)
        }

        It 'rejects discovery/scaffold-only options and OutputPath on pack' {
            { Invoke-PackageForge pack $TestDrive -Output $TestDrive } | Should -Throw '*does not use -OutputPath or -Output*'
            { Invoke-PackageForge pack $TestDrive -OutputPath $TestDrive } | Should -Throw '*does not use -OutputPath or -Output*'
            { Invoke-PackageForge pack $TestDrive -DiscoveryPath 'apps.json' } | Should -Throw '*does not use -DiscoveryPath*'
            { Invoke-PackageForge pack $TestDrive -DiscoveryMatchId 'abc123' } | Should -Throw '*does not use -DiscoveryMatchId*'
            { Invoke-PackageForge pack $TestDrive -DetectionOperator Exact } | Should -Throw '*does not use -DetectionOperator*'
            { Invoke-PackageForge pack $TestDrive -FailOnLowConfidence } | Should -Throw '*does not use -FailOnLowConfidence*'

            Mock New-PSADTPackage { throw 'New-PSADTPackage must not be called.' }
            Mock New-IntuneWinPackage { throw 'New-IntuneWinPackage must not be called.' }
            { Invoke-PackageForge pack } | Should -Throw '*requires an existing scaffold root directory in -Path or -PackagePath*'
            Should -Invoke New-PSADTPackage -Times 0 -Exactly
            Should -Invoke New-IntuneWinPackage -Times 0 -Exactly
        }

        It 'requires an existing scaffold root and PackageManifest.json before anything is invoked' {
            Mock New-PSADTPackage { throw 'New-PSADTPackage must not be called.' }
            Mock New-IntuneWinPackage { throw 'New-IntuneWinPackage must not be called.' }

            $missing = Join-Path $TestDrive 'no-such-root'
            { Invoke-PackageForge pack $missing } | Should -Throw '*requires an existing scaffold root directory*'

            $rootNoManifest = Join-Path $TestDrive 'no-manifest'
            [void] (New-Item -ItemType Directory -Path $rootNoManifest -Force)
            { Invoke-PackageForge -Action pack -PackagePath $rootNoManifest } | Should -Throw '*PackageManifest.json in the scaffold root*'

            Should -Invoke New-PSADTPackage -Times 0 -Exactly
            Should -Invoke New-IntuneWinPackage -Times 0 -Exactly
        }

        It 'stops on NeedsInput readiness without invoking PSADT or Intune' {
            [void] (Get-PackFixture -Root (Join-Path $TestDrive 'ni') -Readiness 'NeedsInput' | Out-Null)
            $needsInputRoot = Join-Path $TestDrive 'ni'

            Mock New-PSADTPackage { throw 'New-PSADTPackage must not be called.' }
            Mock New-IntuneWinPackage { throw 'New-IntuneWinPackage must not be called.' }

            { Invoke-PackageForge pack $needsInputRoot } | Should -Throw "*readiness is 'NeedsInput'*"
            Should -Invoke New-PSADTPackage -Times 0 -Exactly
            Should -Invoke New-IntuneWinPackage -Times 0 -Exactly
        }

        It 'creates PSADT when Package is empty, then delegates to Intune with forwarding, and preserves the created result' {
            $fixture = Get-PackFixture -Root (Join-Path $TestDrive 'create')
            $created = [PSCustomObject] @{
                PSTypeName     = 'PSPackageForge.PSADTPackageResult'
                ManifestPath   = (Join-Path $fixture.Root 'PackageManifest.json')
                PackagePath    = (Join-Path $fixture.Root 'Package')
                PSADTVersion   = '4.0.6'
            }
            Mock New-PSADTPackage { param($ManifestPath, $PSADTModulePath) $script:PackPsadt = @{ ManifestPath = $ManifestPath; PSADTModulePath = $PSADTModulePath }; $created }
            Mock New-IntuneWinPackage { param($OutputPath, $IntuneWinAppUtilPath) $script:PackIntune = @{ OutputPath = $OutputPath; IntuneWinAppUtilPath = $IntuneWinAppUtilPath }; Get-PackIntuneBuiltResult -Root $OutputPath }

            $result = Invoke-PackageForge pack $fixture.Root -PSADTModulePath 'C:\modules\PSADT\PSAppDeployToolkit.psd1' -IntuneWinAppUtilPath 'C:\tools\app.exe'

            $script:PackPsadt.ManifestPath | Should -Be (Join-Path $fixture.Root 'PackageManifest.json')
            $script:PackPsadt.PSADTModulePath | Should -Be 'C:\modules\PSADT\PSAppDeployToolkit.psd1'
            $script:PackIntune.OutputPath | Should -Be $fixture.Root
            $script:PackIntune.IntuneWinAppUtilPath | Should -Be 'C:\tools\app.exe'

            $result.Action | Should -Be 'pack'
            $result.Status | Should -Be 'Completed'
            $result.PSADTDisposition | Should -Be 'Created'
            $result.PSADTResult.PSADTVersion | Should -Be '4.0.6'
            $result.OutputPath | Should -Be $fixture.Root
            $result.PackagePath | Should -Be (Join-Path $fixture.Root 'Package')
            $result.IntuneWinPath | Should -Match '\.intunewin$'
            $result.SHA256 | Should -Match '^[0-9A-F]{64}$'

            Should -Invoke New-PSADTPackage -Times 1 -Exactly
            Should -Invoke New-IntuneWinPackage -Times 1 -Exactly
        }

        It 'forwards nothing when PSADT and Intune tool paths are omitted' {
            $fixture = Get-PackFixture -Root (Join-Path $TestDrive 'create-notool')
            Mock New-PSADTPackage { $script:PackPsadt = @{ ManifestPath = $ManifestPath; PSADTModulePath = $PSADTModulePath }; [PSCustomObject]@{ PSTypeName = 'PSPackageForge.PSADTPackageResult'; ManifestPath = $ManifestPath } }
            Mock New-IntuneWinPackage { $script:PackIntune = @{ OutputPath = $OutputPath; IntuneWinAppUtilPath = $IntuneWinAppUtilPath }; Get-PackIntuneBuiltResult -Root $OutputPath }

            $null = Invoke-PackageForge pack $fixture.Root

            $script:PackPsadt.PSADTModulePath | Should -BeNullOrEmpty
            $script:PackIntune.IntuneWinAppUtilPath | Should -BeNullOrEmpty
        }

        It 'reuses a complete Package without calling PSADT and leaves PSADTResult null' {
            $fixture = Get-PackFixture -Root (Join-Path $TestDrive 'reuse')
            [void] (Get-PackCompletePackage -Fixture $fixture)
            Mock New-PSADTPackage { throw 'New-PSADTPackage must not be called for a valid reuse.' }
            Mock New-IntuneWinPackage { param($OutputPath) Get-PackIntuneBuiltResult -Root $OutputPath }

            $result = Invoke-PackageForge pack $fixture.Root

            $result.Status | Should -Be 'Completed'
            $result.PSADTDisposition | Should -Be 'Reused'
            $result.PSADTResult | Should -BeNullOrEmpty
            $result.OutputPath | Should -Be $fixture.Root
            $result.PackagePath | Should -Be (Join-Path $fixture.Root 'Package')
            $result.IntuneWinPath | Should -Match '\.intunewin$'
            $result.SHA256 | Should -Match '^[0-9A-F]{64}$'

            Should -Invoke New-PSADTPackage -Times 0 -Exactly
            Should -Invoke New-IntuneWinPackage -Times 1 -Exactly
        }

        It 'refuses an occupied IntuneWin output and preserves the existing artifact' {
            $fixture = Get-PackFixture -Root (Join-Path $TestDrive 'occupied-intunewin')
            [void] (Get-PackCompletePackage -Fixture $fixture)
            $intuneOutput = Join-Path $fixture.Root 'IntuneWin'
            [void] (New-Item -ItemType Directory -Path $intuneOutput -Force)
            $sentinel = Join-Path $intuneOutput 'sentinel.intunewin'
            Set-Content -LiteralPath $sentinel -Value 'do not touch' -NoNewline

            Mock New-PSADTPackage { throw 'New-PSADTPackage must not be called for a valid reuse.' }

            { Invoke-PackageForge pack $fixture.Root } | Should -Throw '*empty directory*'
            Test-Path -LiteralPath $sentinel | Should -BeTrue
            Get-Content -LiteralPath $sentinel -Raw | Should -Be 'do not touch'
            Should -Invoke New-PSADTPackage -Times 0 -Exactly
        }

        It 'rejects a partial or corrupt Package, preserves the existing content, and does not delete or replace it' {
            $fixture = Get-PackFixture -Root (Join-Path $TestDrive 'partial')
            [void] (Get-PackCompletePackage -Fixture $fixture)
            $sentinel = Join-Path (Join-Path $fixture.Root 'Package') 'sentinel.txt'
            Set-Content -LiteralPath $sentinel -Value 'do not touch'

            Mock New-PSADTPackage { throw 'New-PSADTPackage must not be called on reuse.' }
            Mock New-IntuneWinPackage { throw 'New-IntuneWinPackage must not be called.' }

            # Remove one required artifact to make the package partial.
            Remove-Item -LiteralPath (Join-Path (Join-Path $fixture.Root 'Package') 'Invoke-AppDeployToolkit.exe') -Force

            { Invoke-PackageForge pack $fixture.Root } | Should -Throw '*partial or corrupt*'

            Test-Path -LiteralPath $sentinel | Should -BeTrue
            Get-Content -LiteralPath $sentinel | Should -Be 'do not touch'
            Test-Path -LiteralPath (Join-Path (Join-Path $fixture.Root 'Package') 'Invoke-AppDeployToolkit.exe') | Should -BeFalse
            Should -Invoke New-PSADTPackage -Times 0 -Exactly
            Should -Invoke New-IntuneWinPackage -Times 0 -Exactly
        }

        It 'rejects a packaged installer hash mismatch without deleting or replacing content' {
            $fixture = Get-PackFixture -Root (Join-Path $TestDrive 'hashmismatch')
            [void] (Get-PackCompletePackage -Fixture $fixture)
            $sentinel = Join-Path (Join-Path $fixture.Root 'Package') 'sentinel.txt'
            Set-Content -LiteralPath $sentinel -Value 'do not touch'

            $staged = Join-Path $fixture.Root $fixture.InstallerFileName
            Remove-Item -LiteralPath $staged -Force
            Set-Content -LiteralPath $staged -Value 'tampered installer' -NoNewline
            $tamperedHash = (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash
            $manifestPath = Join-Path $fixture.Root 'PackageManifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $manifest = $manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $manifest.Installer.SHA256 = $tamperedHash
            $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

            Mock New-PSADTPackage { throw 'New-PSADTPackage must not be called on reuse.' }
            Mock New-IntuneWinPackage { throw 'New-IntuneWinPackage must not be called.' }

            { Invoke-PackageForge pack $fixture.Root } | Should -Throw '*hash mismatch*'
            Test-Path -LiteralPath $sentinel | Should -BeTrue
            Get-Content -LiteralPath $sentinel | Should -Be 'do not touch'
            Should -Invoke New-PSADTPackage -Times 0 -Exactly
            Should -Invoke New-IntuneWinPackage -Times 0 -Exactly
        }

        It 'rejects either literal separator in reuse metadata without calling pack primitives or replacing content' {
            foreach ($separator in @('\', '/')) {
                $fixtureName = 'slash-separator'
                if ($separator -eq '\') { $fixtureName = 'backslash-separator' }
                $fixture = Get-PackFixture -Root (Join-Path $TestDrive $fixtureName)
                [void] (Get-PackCompletePackage -Fixture $fixture)
                $sentinel = Join-Path (Join-Path $fixture.Root 'Package') 'sentinel.txt'
                Set-Content -LiteralPath $sentinel -Value 'do not touch' -NoNewline

                $manifestPath = Join-Path $fixture.Root 'PackageManifest.json'
                $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                $manifest = $manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $manifest.Installer.Path = "setup$separator.exe"
                $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

                Mock New-PSADTPackage { throw 'New-PSADTPackage must not be called for invalid reuse metadata.' }
                Mock New-IntuneWinPackage { throw 'New-IntuneWinPackage must not be called for invalid reuse metadata.' }

                { Invoke-PackageForge pack $fixture.Root } | Should -Throw '*cannot be validated for reuse*'
                Test-Path -LiteralPath $sentinel | Should -BeTrue
                Get-Content -LiteralPath $sentinel -Raw | Should -Be 'do not touch'
                Should -Invoke New-PSADTPackage -Times 0 -Exactly
                Should -Invoke New-IntuneWinPackage -Times 0 -Exactly
            }
        }

        It 'propagates InstructionsOnly status, findings, and keeps the artifact fields null' {
            $fixture = Get-PackFixture -Root (Join-Path $TestDrive 'instructions')
            Mock New-PSADTPackage { param($ManifestPath) [PSCustomObject] @{ PSTypeName = 'PSPackageForge.PSADTPackageResult'; ManifestPath = $ManifestPath } }
            Mock New-IntuneWinPackage { param($OutputPath) Get-PackIntuneInstructionsResult -Root $OutputPath }

            $result = Invoke-PackageForge pack $fixture.Root

            $result.Status | Should -Be 'InstructionsOnly'
            $result.PSADTDisposition | Should -Be 'Created'
            $result.IntuneWinPath | Should -BeNullOrEmpty
            $result.SHA256 | Should -BeNullOrEmpty
            $result.Findings.Code | Should -Contain 'INTUNEWINAPPUTIL_UNAVAILABLE'
            $result.IntuneWinResult.Status | Should -Be 'InstructionsOnly'
            Should -Invoke New-PSADTPackage -Times 1 -Exactly
            Should -Invoke New-IntuneWinPackage -Times 1 -Exactly
        }

        It 'orders PSADT handling before Intune' {
            $fixture = Get-PackFixture -Root (Join-Path $TestDrive 'order')

            $script:PackOrder = @()
            Mock New-PSADTPackage { $script:PackOrder += 'psadt'; [PSCustomObject] @{ PSTypeName = 'PSPackageForge.PSADTPackageResult'; ManifestPath = $ManifestPath } }
            Mock New-IntuneWinPackage { $script:PackOrder += 'intune'; Get-PackIntuneBuiltResult -Root $OutputPath }

            $null = Invoke-PackageForge pack $fixture.Root

            # Create branch: the dispatcher must resolve PSADT before it ever delegates
            # to the Intune builder, which owns the Package source, setup, and artifact rules.
            $script:PackOrder | Should -Be @('psadt', 'intune')
            Should -Invoke New-PSADTPackage -Times 1 -Exactly
            Should -Invoke New-IntuneWinPackage -Times 1 -Exactly
        }

        It 'keeps WhatIf read-only on the create branch (WouldCreate)' {
            $fixture = Get-PackFixture -Root (Join-Path $TestDrive 'whatif-create')
            Mock New-PSADTPackage {
                param($ManifestPath, $PSADTModulePath, [switch] $WhatIf)
                $script:PackPsadt = @{ ManifestPath = $ManifestPath; PSADTModulePath = $PSADTModulePath; WhatIf = $WhatIf.IsPresent }
                [PSCustomObject] @{ PSTypeName = 'PSPackageForge.PSADTPackageResult'; ManifestPath = $ManifestPath }
            }
            Mock New-IntuneWinPackage { throw 'New-IntuneWinPackage must not be called on the create WhatIf branch.' }

            $result = Invoke-PackageForge pack $fixture.Root -PSADTModulePath 'C:\modules\PSADT\PSAppDeployToolkit.psd1' -WhatIf

            $script:PackPsadt.ManifestPath | Should -Be (Join-Path $fixture.Root 'PackageManifest.json')
            $script:PackPsadt.PSADTModulePath | Should -Be 'C:\modules\PSADT\PSAppDeployToolkit.psd1'
            $script:PackPsadt.WhatIf | Should -BeTrue
            $result.Status | Should -Be 'WhatIf'
            $result.PSADTDisposition | Should -Be 'WouldCreate'
            $result.OutputPath | Should -Be $fixture.Root
            $result.PackagePath | Should -Be (Join-Path $fixture.Root 'Package')
            $result.PSADTResult.ManifestPath | Should -Be (Join-Path $fixture.Root 'PackageManifest.json')
            $result.IntuneWinResult | Should -BeNullOrEmpty
            $result.IntuneWinPath | Should -BeNullOrEmpty
            $result.SHA256 | Should -BeNullOrEmpty
            Should -Invoke New-PSADTPackage -Times 1 -Exactly
            Should -Invoke New-IntuneWinPackage -Times 0 -Exactly
        }

        It 'keeps WhatIf read-only on the reuse branch (WouldReuse) and forwards Intune preview' {
            $fixture = Get-PackFixture -Root (Join-Path $TestDrive 'whatif-reuse')
            [void] (Get-PackCompletePackage -Fixture $fixture)
            Mock New-PSADTPackage { throw 'New-PSADTPackage must not be called on the reuse WhatIf branch.' }
            Mock New-IntuneWinPackage {
                param($OutputPath, $IntuneWinAppUtilPath, [switch] $WhatIf)
                $script:PackIntune = @{ OutputPath = $OutputPath; IntuneWinAppUtilPath = $IntuneWinAppUtilPath; WhatIf = $WhatIf.IsPresent }
                Get-PackPreviewResult
            }

            $result = Invoke-PackageForge pack $fixture.Root -IntuneWinAppUtilPath 'C:\tools\app.exe' -WhatIf

            $script:PackIntune.OutputPath | Should -Be $fixture.Root
            $script:PackIntune.IntuneWinAppUtilPath | Should -Be 'C:\tools\app.exe'
            $script:PackIntune.WhatIf | Should -BeTrue
            $result.Status | Should -Be 'WhatIf'
            $result.PSADTDisposition | Should -Be 'WouldReuse'
            $result.OutputPath | Should -Be $fixture.Root
            $result.PackagePath | Should -Be (Join-Path $fixture.Root 'Package')
            $result.PSADTResult | Should -BeNullOrEmpty
            $result.IntuneWinPath | Should -BeNullOrEmpty
            $result.SHA256 | Should -BeNullOrEmpty
            Should -Invoke New-PSADTPackage -Times 0 -Exactly
            Should -Invoke New-IntuneWinPackage -Times 1 -Exactly
        }
    }

    Describe 'Invoke-PackageForge exported alias end-to-end smoke test' {
        It 'routes the exact psforge discover, scaffold, and pack forms with positional paths' {
            (Get-Alias -Name psforge -ErrorAction Stop).Definition | Should -Be 'Invoke-PackageForge'

            $discoveryPath = Join-Path $TestDrive 'alias-discovery.json'
            Mock Get-InstalledAppInfo {
                param([string] $DisplayNameLike, [string] $OutputPath, [switch] $WhatIf)
                [void] $DisplayNameLike
                [void] $WhatIf

                [PSCustomObject] @{
                    PSTypeName  = 'PSPackageForge.InstalledAppDiscoveryResult'
                    Matches     = @([PSCustomObject] @{ MatchId = 'alias-match'; DisplayName = 'Alias App' })
                    Findings    = @()
                    DiscoveryPath = $OutputPath
                }
            }

            $discover = psforge discover 'Alias App*' -OutputPath $discoveryPath

            $installerPath = Join-Path $TestDrive 'AliasApp.msi'
            Set-Content -LiteralPath $installerPath -Value 'installer' -NoNewline
            $scaffoldPath = Join-Path $TestDrive 'alias-scaffold'
            Mock New-PackageScaffold {
                param([string] $Path, [string] $OutputPath)

                [PSCustomObject] @{
                    PSTypeName    = 'PSPackageForge.ScaffoldResult'
                    InstallerInfo = [PSCustomObject] @{ Path = $Path; Findings = @() }
                    ManifestPath  = Join-Path $OutputPath 'PackageManifest.json'
                    DocumentPath  = Join-Path $OutputPath 'PackageDocument.md'
                    DetectionPath = Join-Path $OutputPath 'Detect-Application.ps1'
                    OutputPath    = $OutputPath
                    Readiness     = 'ReviewRequired'
                }
            }

            $scaffold = psforge scaffold $installerPath -Output $scaffoldPath

            $packRoot = Join-Path $TestDrive 'alias-pack'
            $null = New-Item -ItemType Directory -Path (Join-Path $packRoot 'Package') -Force
            $manifest = [ordered]@{
                SchemaVersion = '1.0'
                Installer     = [ordered]@{ Path = 'AliasApp.exe'; FileName = 'AliasApp.exe'; SHA256 = ('A' * 64) }
                Readiness     = 'ReviewRequired'
            }
            $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $packRoot 'PackageManifest.json')

            Mock New-PSADTPackage {
                param([string] $ManifestPath)
                [PSCustomObject] @{ PSTypeName = 'PSPackageForge.PSADTPackageResult'; ManifestPath = $ManifestPath }
            }
            Mock New-IntuneWinPackage {
                param([string] $OutputPath)
                [PSCustomObject] @{
                    PSTypeName    = 'PSPackageForge.IntuneWinPackageResult'
                    Status        = 'Built'
                    IntuneWinPath = Join-Path $OutputPath 'IntuneWin\AliasApp.intunewin'
                    SHA256        = ('B' * 64)
                    Findings      = @()
                }
            }

            $pack = psforge pack $packRoot

            $discover.Action | Should -Be 'discover'
            $discover.OutputPath | Should -BeNullOrEmpty
            $discover.DiscoveryPath | Should -Be $discoveryPath
            $discover.Matches[0].MatchId | Should -Be 'alias-match'
            $scaffold.Action | Should -Be 'scaffold'
            $scaffold.OutputPath | Should -Be ([System.IO.Path]::GetFullPath($scaffoldPath))
            $scaffold.PackagePath | Should -Be (Join-Path ([System.IO.Path]::GetFullPath($scaffoldPath)) 'Package')
            $pack.Action | Should -Be 'pack'
            $pack.OutputPath | Should -Be ([System.IO.Path]::GetFullPath($packRoot))
            $pack.PackagePath | Should -Be (Join-Path ([System.IO.Path]::GetFullPath($packRoot)) 'Package')
            $pack.IntuneWinPath | Should -Be (Join-Path ([System.IO.Path]::GetFullPath($packRoot)) 'IntuneWin\AliasApp.intunewin')

            Should -Invoke Get-InstalledAppInfo -Times 1 -Exactly -ParameterFilter {
                $DisplayNameLike -eq 'Alias App*' -and $OutputPath -eq $discoveryPath
            }
            Should -Invoke New-PackageScaffold -Times 1 -Exactly -ParameterFilter {
                $Path -eq $installerPath -and $OutputPath -eq ([System.IO.Path]::GetFullPath($scaffoldPath))
            }
            Should -Invoke New-PSADTPackage -Times 1 -Exactly -ParameterFilter {
                $ManifestPath -eq (Join-Path ([System.IO.Path]::GetFullPath($packRoot)) 'PackageManifest.json')
            }
            Should -Invoke New-IntuneWinPackage -Times 1 -Exactly -ParameterFilter {
                $OutputPath -eq ([System.IO.Path]::GetFullPath($packRoot))
            }
        }
    }
}

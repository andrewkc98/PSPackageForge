<#
    Unit tests for reference-machine installed-application discovery.

    The registry boundary is mocked in every test. This keeps the suite runnable on macOS
    and Linux, and proves that the public command asks for explicit registry views instead
    of inheriting the bitness of the PowerShell host.
#>

$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

BeforeAll {
    function global:New-TestRegistryUninstallEntry {
        param(
            [string] $Hive = 'LocalMachine',
            [string] $View = 'Registry64',
            [string] $SubKey = 'Acme App',
            [string] $DisplayName = 'Acme App',
            [string] $Publisher = 'Acme Corporation',
            [string] $DisplayVersion = '1.2.3',
            [string] $InstallLocation = '%ProgramFiles%\Acme App',
            [string] $QuietUninstallString = '',
            [string] $UninstallString = '',
            [string] $DisplayIcon = '',
            [int] $WindowsInstaller = 0,
            [int] $SystemComponent = 0
        )

        [PSCustomObject] @{
            PSTypeName           = 'PSPackageForge.RegistryUninstallEntry'
            Hive                 = $Hive
            View                 = $View
            SubKey               = $SubKey
            DisplayName          = $DisplayName
            Publisher            = $Publisher
            DisplayVersion       = $DisplayVersion
            InstallLocation      = $InstallLocation
            QuietUninstallString = $QuietUninstallString
            UninstallString      = $UninstallString
            DisplayIcon          = $DisplayIcon
            WindowsInstaller     = $WindowsInstaller
            SystemComponent      = $SystemComponent
        }
    }

    function global:Get-TestEvidenceRecord {
        param(
            [Parameter(Mandatory)] $Match,
            [Parameter(Mandatory)] [string] $Field
        )

        return $Match.Evidence | Where-Object { $_.Field -eq $Field } | Select-Object -First 1
    }
}

AfterAll {
    Remove-Item -Path 'function:global:New-TestRegistryUninstallEntry',
        'function:global:Get-TestEvidenceRecord' -ErrorAction SilentlyContinue
}

InModuleScope PSPackageForge {

    Describe 'Get-InstalledAppInfo registry discovery' {

        BeforeEach {
            $script:RegistryRows = @{
                'LocalMachine|Registry64' = @()
                'LocalMachine|Registry32' = @()
                'CurrentUser|Registry64'  = @()
            }
            $script:RegistryErrors = @{}

            Mock Get-RegistryUninstallEntry {
                param($Hive, $View)

                $key = '{0}|{1}' -f $Hive, $View
                if ($script:RegistryErrors.ContainsKey($key)) {
                    throw [System.UnauthorizedAccessException]::new($script:RegistryErrors[$key])
                }

                return @($script:RegistryRows[$key])
            }
        }

        It 'enumerates explicit 64-bit, 32-bit, and current-user registry views' {
            $null = Get-InstalledAppInfo -DisplayNameLike 'Acme*'

            Should -Invoke Get-RegistryUninstallEntry -Times 1 -Exactly -ParameterFilter {
                $Hive -eq 'LocalMachine' -and $View -eq 'Registry64'
            }
            Should -Invoke Get-RegistryUninstallEntry -Times 1 -Exactly -ParameterFilter {
                $Hive -eq 'LocalMachine' -and $View -eq 'Registry32'
            }
            Should -Invoke Get-RegistryUninstallEntry -Times 1 -Exactly -ParameterFilter {
                $Hive -eq 'CurrentUser' -and $View -eq 'Registry64'
            }
        }

        It 'returns every matching registration separately with stable unique IDs' {
            $script:RegistryRows['LocalMachine|Registry64'] = @(
                New-TestRegistryUninstallEntry -SubKey 'Acme-x64' -DisplayName 'Acme App' -View 'Registry64'
            )
            $script:RegistryRows['LocalMachine|Registry32'] = @(
                New-TestRegistryUninstallEntry -SubKey 'Acme-x86' -DisplayName 'Acme App' -View 'Registry32'
            )

            $first  = Get-InstalledAppInfo -DisplayNameLike 'Acme*'
            $second = Get-InstalledAppInfo -DisplayNameLike 'Acme*'

            $first.Matches.Count | Should -Be 2
            @($first.Matches.MatchId | Select-Object -Unique).Count | Should -Be 2
            $first.Matches.MatchId | Should -Be $second.Matches.MatchId
            foreach ($match in $first.Matches) {
                $match.MatchId | Should -Match '^[0-9a-f]{64}$'
                $match.RegistryIdentity.Hive   | Should -Be 'LocalMachine'
                $match.RegistryIdentity.SubKey | Should -BeLike 'Acme-*'
            }
        }

        It 'filters DisplayName using wildcard semantics' {
            $script:RegistryRows['LocalMachine|Registry64'] = @(
                New-TestRegistryUninstallEntry -SubKey 'Acme' -DisplayName 'Acme Editor'
                New-TestRegistryUninstallEntry -SubKey 'Other' -DisplayName 'Other Editor'
            )

            $result = Get-InstalledAppInfo -DisplayNameLike 'Acme*'

            $result.Matches.Count       | Should -Be 1
            $result.Matches.DisplayName | Should -Be 'Acme Editor'
        }

        It 'emits a finding instead of fabricating evidence when nothing matches' {
            $result = Get-InstalledAppInfo -DisplayNameLike 'Missing Product*'

            $result.Matches | Should -BeNullOrEmpty
            ($result.Findings | Where-Object Code -eq 'INSTALLED_APP_NOT_FOUND') |
                Should -Not -BeNullOrEmpty
        }

        It 'continues other registry roots after one view cannot be read' {
            $script:RegistryErrors['LocalMachine|Registry64'] = 'Access denied for test.'
            $script:RegistryRows['LocalMachine|Registry32'] = @(
                New-TestRegistryUninstallEntry -SubKey 'Acme-x86' -DisplayName 'Acme App' -View 'Registry32'
            )

            $result = Get-InstalledAppInfo -DisplayNameLike 'Acme*'

            $result.Matches.Count | Should -Be 1
            ($result.Findings | Where-Object Code -eq 'INSTALLED_APP_REGISTRY_READ_FAILED') |
                Should -Not -BeNullOrEmpty
            Should -Invoke Get-RegistryUninstallEntry -Times 1 -Exactly -ParameterFilter {
                $Hive -eq 'CurrentUser' -and $View -eq 'Registry64'
            }
        }

        It 'continues the same registry view after one entry cannot be read' {
            $script:RegistryRows['LocalMachine|Registry64'] = @(
                [PSCustomObject] @{
                    PSTypeName = 'PSPackageForge.RegistryUninstallEntryReadError'
                    Hive = 'LocalMachine'; View = 'Registry64'; SubKey = 'Unreadable'; ReadError = $true
                }
                New-TestRegistryUninstallEntry -SubKey 'Acme-readable' -DisplayName 'Acme App'
            )

            $result = Get-InstalledAppInfo -DisplayNameLike 'Acme*'

            $result.Matches.Count | Should -Be 1
            ($result.Findings | Where-Object Code -eq 'INSTALLED_APP_ENTRY_READ_FAILED') |
                Should -Not -BeNullOrEmpty
        }

        It 'maps identity, location, context, and registry-view architecture with provenance' {
            $script:RegistryRows['LocalMachine|Registry64'] = @(
                New-TestRegistryUninstallEntry `
                    -DisplayName 'Acme Editor' `
                    -Publisher 'Acme Corporation' `
                    -DisplayVersion '4.5.6' `
                    -InstallLocation '%ProgramFiles%\Acme Editor'
            )

            $match = (Get-InstalledAppInfo -DisplayNameLike 'Acme*').Matches[0]

            (Get-TestEvidenceRecord $match 'ProductName').Value       | Should -Be 'Acme Editor'
            (Get-TestEvidenceRecord $match 'Manufacturer').Value      | Should -Be 'Acme Corporation'
            (Get-TestEvidenceRecord $match 'ProductVersionRaw').Value | Should -Be '4.5.6'
            (Get-TestEvidenceRecord $match 'InstallLocation').Value   | Should -Be '%ProgramFiles%\Acme Editor'
            (Get-TestEvidenceRecord $match 'SelectedContext').Value   | Should -Be 'System'
            (Get-TestEvidenceRecord $match 'Architecture').Value      | Should -Be 'x64'

            foreach ($record in $match.Evidence) {
                $record.Source | Should -Be ([EvidenceSource]::Registry)
            }
            (Get-TestEvidenceRecord $match 'ProductName').Confidence     | Should -Be ([ConfidenceLevel]::High)
            (Get-TestEvidenceRecord $match 'InstallLocation').Confidence | Should -Be ([ConfidenceLevel]::High)
            (Get-TestEvidenceRecord $match 'SelectedContext').Confidence | Should -Be ([ConfidenceLevel]::High)
            (Get-TestEvidenceRecord $match 'Architecture').Confidence    | Should -Be ([ConfidenceLevel]::Medium)
        }

        It 'maps a current-user registration to User context' {
            $script:RegistryRows['CurrentUser|Registry64'] = @(
                New-TestRegistryUninstallEntry -Hive 'CurrentUser' -SubKey 'Acme-user' -DisplayName 'Acme User App'
            )

            $match = (Get-InstalledAppInfo -DisplayNameLike 'Acme*').Matches[0]

            (Get-TestEvidenceRecord $match 'SelectedContext').Value | Should -Be 'User'
            (Get-TestEvidenceRecord $match 'SelectedContext').Confidence |
                Should -Be ([ConfidenceLevel]::High)
        }

        It 'emits a high-confidence structured MSI uninstall for a confirmed MSI registration' {
            $productCode = '{11111111-2222-3333-4444-555555555555}'
            $script:RegistryRows['LocalMachine|Registry64'] = @(
                New-TestRegistryUninstallEntry `
                    -SubKey $productCode `
                    -DisplayName 'Acme MSI App' `
                    -WindowsInstaller 1
            )

            $match   = (Get-InstalledAppInfo -DisplayNameLike 'Acme*').Matches[0]
            $command = Get-TestEvidenceRecord $match 'UninstallCommand'

            (Get-TestEvidenceRecord $match 'ProductCode').Value | Should -Be $productCode
            (Get-TestEvidenceRecord $match 'ProductCodePresent').Value | Should -BeTrue
            (Get-TestEvidenceRecord $match 'SupportsMsiUninstall').Value | Should -BeTrue
            $command.Confidence         | Should -Be ([ConfidenceLevel]::High)
            $command.Value.Executable   | Should -BeLike '*msiexec*'
            $command.Value.ArgumentList | Should -Contain '/x'
            $command.Value.ArgumentList | Should -Contain $productCode
            $command.Value.ArgumentList | Should -Contain '/qn'
        }

        It 'refuses a malformed MSI registration rather than treating its subkey as a product code' {
            $script:RegistryRows['LocalMachine|Registry64'] = @(
                New-TestRegistryUninstallEntry `
                    -SubKey 'not-a-product-code' `
                    -DisplayName 'Acme Broken MSI' `
                    -WindowsInstaller 1
            )

            $match = (Get-InstalledAppInfo -DisplayNameLike 'Acme*').Matches[0]

            Get-TestEvidenceRecord $match 'ProductCode' | Should -BeNullOrEmpty
            ($match.Findings | Where-Object Code -eq 'INSTALLED_APP_MSI_REGISTRATION_INVALID') |
                Should -Not -BeNullOrEmpty
        }

        It 'prefers and parses QuietUninstallString without inventing switches' {
            $script:RegistryRows['LocalMachine|Registry64'] = @(
                New-TestRegistryUninstallEntry `
                    -QuietUninstallString '"%ProgramFiles%\Acme App\uninstall.exe" /S /norestart' `
                    -UninstallString '"%ProgramFiles%\Acme App\uninstall.exe"'
            )

            $match   = (Get-InstalledAppInfo -DisplayNameLike 'Acme*').Matches[0]
            $command = Get-TestEvidenceRecord $match 'UninstallCommand'

            $command | Should -Not -BeNullOrEmpty
            $command.Confidence         | Should -Be ([ConfidenceLevel]::High)
            $command.Value.Executable   | Should -Be '%ProgramFiles%\Acme App\uninstall.exe'
            $command.Value.ArgumentList | Should -Be @('/S', '/norestart')
            ($match.Findings | Where-Object Code -eq 'INSTALLED_APP_UNINSTALL_SILENCE_UNVERIFIED') |
                Should -BeNullOrEmpty
        }

        It 'marks a safely parsed plain uninstall string as silence and exit-code unverified' {
            $script:RegistryRows['LocalMachine|Registry64'] = @(
                New-TestRegistryUninstallEntry `
                    -UninstallString '"%ProgramFiles%\Acme App\uninstall.exe" /remove'
            )

            $match   = (Get-InstalledAppInfo -DisplayNameLike 'Acme*').Matches[0]
            $command = Get-TestEvidenceRecord $match 'UninstallCommand'

            $command.Confidence | Should -Be ([ConfidenceLevel]::Medium)
            $command.Value.ArgumentList | Should -Be @('/remove')
            ($match.Findings | Where-Object Code -eq 'INSTALLED_APP_UNINSTALL_SILENCE_UNVERIFIED') |
                Should -Not -BeNullOrEmpty
            ($match.Findings | Where-Object Code -eq 'INSTALLED_APP_EXIT_CODES_UNVERIFIED') |
                Should -Not -BeNullOrEmpty
        }

        It 'refuses an ambiguous unquoted uninstall command rather than guessing its executable' {
            $script:RegistryRows['LocalMachine|Registry64'] = @(
                New-TestRegistryUninstallEntry `
                    -UninstallString 'C:\Program Files\Acme App\uninstall.exe /S'
            )

            $match = (Get-InstalledAppInfo -DisplayNameLike 'Acme*').Matches[0]

            Get-TestEvidenceRecord $match 'UninstallCommand' | Should -BeNullOrEmpty
            ($match.Findings | Where-Object Code -eq 'INSTALLED_APP_UNINSTALL_COMMAND_UNRESOLVED') |
                Should -Not -BeNullOrEmpty
        }

        It 'tokenizes a user-profile prefix before a registry path leaves the read boundary' {
            $oldUserProfile = [Environment]::GetEnvironmentVariable('UserProfile')
            try {
                $testUserProfile = 'C:\Users\[user]'
                [Environment]::SetEnvironmentVariable('UserProfile', $testUserProfile)

                $portable = ConvertTo-ForgePortablePath -Value ($testUserProfile + '\AppData\Local\Acme')

                $portable | Should -Be '%USERPROFILE%\AppData\Local\Acme'
                $portable | Should -Not -Match '\[user\]'
            }
            finally {
                [Environment]::SetEnvironmentVariable('UserProfile', $oldUserProfile)
            }
        }

        It 'does not infer a file detection target from an unverifiable icon path' {
            $script:RegistryRows['LocalMachine|Registry64'] = @(
                New-TestRegistryUninstallEntry -DisplayIcon '%ProgramFiles%\Acme App\missing.exe,0'
            )

            $match = (Get-InstalledAppInfo -DisplayNameLike 'Acme*').Matches[0]

            Get-TestEvidenceRecord $match 'DetectionTarget' | Should -BeNullOrEmpty
            ($match.Findings | Where-Object Code -eq 'INSTALLED_APP_DETECTION_TARGET_UNRESOLVED') |
                Should -Not -BeNullOrEmpty
        }

        It 'uses a validated application icon as Medium-confidence detection evidence' {
            Mock Test-Path { return $true } -ParameterFilter {
                $PathType -eq 'Leaf' -and $LiteralPath -like '*Acme App\Acme.exe'
            }
            $script:RegistryRows['LocalMachine|Registry64'] = @(
                New-TestRegistryUninstallEntry `
                    -InstallLocation '%ProgramFiles%\Acme App' `
                    -DisplayIcon '"%ProgramFiles%\Acme App\Acme.exe",0'
            )

            $match = (Get-InstalledAppInfo -DisplayNameLike 'Acme*').Matches[0]
            $record = Get-TestEvidenceRecord $match 'DetectionTarget'

            $record.Value      | Should -Be '%ProgramFiles%\Acme App\Acme.exe'
            $record.Confidence | Should -Be ([ConfidenceLevel]::Medium)
            ($match.Findings | Where-Object Code -eq 'INSTALLED_APP_DETECTION_TARGET_INFERRED') |
                Should -Not -BeNullOrEmpty
        }
    }

    Describe 'Get-InstalledAppInfo discovery JSON' {

        BeforeEach {
            Mock Get-RegistryUninstallEntry {
                param($Hive, $View)

                if ($Hive -eq 'LocalMachine' -and $View -eq 'Registry64') {
                    return @(New-TestRegistryUninstallEntry -DisplayName 'Acme App')
                }
                return @()
            }
        }

        It 'returns the versioned public discovery contract' {
            $result = Get-InstalledAppInfo -DisplayNameLike 'Acme*'

            $result.PSTypeNames | Should -Contain 'PSPackageForge.InstalledAppDiscoveryResult'
            $result.SchemaVersion  | Should -Be '1.0'
            $result.GeneratedAtUtc | Should -Not -BeNullOrEmpty
            $result.Query.DisplayNameLike | Should -Be 'Acme*'
            $result.Matches.Count   | Should -Be 1
            $result.Findings        | Should -BeNullOrEmpty
        }

        It 'writes JSON with string enum values that round-trips the discovery shape' {
            $outputPath = Join-Path $TestDrive 'discovery.json'

            $result = Get-InstalledAppInfo -DisplayNameLike 'Acme*' -OutputPath $outputPath
            $json   = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json

            $result.DiscoveryPath | Should -Be (Resolve-Path -LiteralPath $outputPath).ProviderPath
            $json.SchemaVersion   | Should -Be '1.0'
            $json.Query.DisplayNameLike | Should -Be 'Acme*'
            $json.Matches.Count   | Should -Be 1
            $json.Matches[0].Evidence[0].Source     | Should -Be 'Registry'
            $json.Matches[0].Evidence[0].Confidence | Should -BeIn @('High', 'Medium', 'Low')
        }

        It 'honors WhatIf and does not write discovery JSON' {
            $outputPath = Join-Path $TestDrive 'whatif-discovery.json'

            $result = Get-InstalledAppInfo -DisplayNameLike 'Acme*' -OutputPath $outputPath -WhatIf

            Test-Path -LiteralPath $outputPath | Should -BeFalse
            $result.Matches.Count | Should -Be 1
        }
    }

    Describe 'Read-InstalledAppDiscoveryData' {

        BeforeEach {
            $script:DiscoveryPath = Join-Path $TestDrive 'installed-app.discovery.json'
            $script:FirstMatchId = Get-InstalledAppMatchId `
                -Hive LocalMachine `
                -View Registry64 `
                -SubKey 'Acme App'
            $script:SecondMatchId = Get-InstalledAppMatchId `
                -Hive LocalMachine `
                -View Registry64 `
                -SubKey 'Acme Helper'

            $script:FirstMatch = [ordered] @{
                MatchId          = $script:FirstMatchId
                DisplayName      = 'Acme App'
                RegistryIdentity = [ordered] @{
                    Hive = 'LocalMachine'; View = 'Registry64'; SubKey = 'Acme App'
                }
                Evidence = @(
                    [ordered] @{
                        Field = 'ProductName'; Value = 'Acme App'; Source = 'Registry'
                        Confidence = 'High'; Notes = 'Observed DisplayName.'
                    }
                    [ordered] @{
                        Field = 'UninstallCommand'
                        Value = [ordered] @{
                            Executable = '%ProgramFiles%\Acme App\uninstall.exe'
                            ArgumentList = @('/S')
                            ExpectedExitCodes = @(0)
                        }
                        Source = 'Registry'; Confidence = 'High'
                    }
                )
                ResolvedEvidence = @()
                Findings = @(
                    [ordered] @{
                        Severity = 'Info'; Code = 'INSTALLED_APP_EXIT_CODES_UNVERIFIED'
                        Message = 'Only exit code zero is modeled.'; Field = 'UninstallCommand'
                    }
                )
            }

            $script:DiscoveryDocument = [ordered] @{
                SchemaVersion  = '1.0'
                GeneratedAtUtc = '2026-08-26T12:00:00.0000000Z'
                Query          = [ordered] @{ DisplayNameLike = 'Acme*' }
                Matches        = @($script:FirstMatch)
                Findings       = @(
                    [ordered] @{
                        Severity = 'Warning'; Code = 'INSTALLED_APP_REGISTRY_READ_FAILED'
                        Message = 'One registry view could not be read.'
                    }
                )
            }
        }

        It 'auto-selects a sole match and re-attributes evidence to reviewed discovery JSON' {
            $script:DiscoveryDocument | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:DiscoveryPath -Encoding UTF8

            $result = Read-InstalledAppDiscoveryData -Path $script:DiscoveryPath

            $result.Provider | Should -Be 'DiscoveryJson'
            $result.MatchId  | Should -Be $script:FirstMatchId
            $result.Path     | Should -Be (Resolve-Path -LiteralPath $script:DiscoveryPath).ProviderPath
            foreach ($record in $result.Evidence) {
                $record.Source | Should -Be ([EvidenceSource]::DiscoveryJson)
                $record.Notes  | Should -BeLike '*original source Registry*'
            }
            $result.Findings.Code | Should -Contain 'INSTALLED_APP_REGISTRY_READ_FAILED'
            $result.Findings.Code | Should -Contain 'INSTALLED_APP_EXIT_CODES_UNVERIFIED'
        }

        It 'rehydrates a structured command as a dictionary rather than a JSON object or string' {
            $script:DiscoveryDocument | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:DiscoveryPath -Encoding UTF8

            $result  = Read-InstalledAppDiscoveryData -Path $script:DiscoveryPath
            $command = $result.Evidence | Where-Object Field -eq 'UninstallCommand'

            ($command.Value -is [System.Collections.IDictionary]) | Should -BeTrue
            $command.Value['Executable']        | Should -Be '%ProgramFiles%\Acme App\uninstall.exe'
            $command.Value['ArgumentList']      | Should -Be @('/S')
            $command.Value['ExpectedExitCodes'] | Should -Be @(0)
        }

        It 'requires an explicit match ID when discovery contains multiple matches' {
            $second = [ordered] @{}
            foreach ($key in $script:FirstMatch.Keys) { $second[$key] = $script:FirstMatch[$key] }
            $second.MatchId     = $script:SecondMatchId
            $second.DisplayName = 'Acme Helper'
            $second.RegistryIdentity = [ordered] @{
                Hive = 'LocalMachine'; View = 'Registry64'; SubKey = 'Acme Helper'
            }
            $script:DiscoveryDocument.Matches = @($script:FirstMatch, $second)
            $script:DiscoveryDocument | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:DiscoveryPath -Encoding UTF8

            { Read-InstalledAppDiscoveryData -Path $script:DiscoveryPath } |
                Should -Throw '*Supply -DiscoveryMatchId*'

            $selected = Read-InstalledAppDiscoveryData `
                -Path $script:DiscoveryPath `
                -MatchId $script:SecondMatchId
            $selected.MatchId | Should -Be $script:SecondMatchId
        }

        It 'rejects unsupported schemas, unknown IDs, duplicate IDs, and empty evidence' {
            $script:DiscoveryDocument.SchemaVersion = '2.0'
            $script:DiscoveryDocument | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:DiscoveryPath -Encoding UTF8
            { Read-InstalledAppDiscoveryData -Path $script:DiscoveryPath } |
                Should -Throw '*not supported*'

            $script:DiscoveryDocument.SchemaVersion = '1.0'
            $script:DiscoveryDocument | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:DiscoveryPath -Encoding UTF8
            { Read-InstalledAppDiscoveryData -Path $script:DiscoveryPath -MatchId $script:SecondMatchId } |
                Should -Throw '*was not found*'

            $duplicate = [ordered] @{}
            foreach ($key in $script:FirstMatch.Keys) { $duplicate[$key] = $script:FirstMatch[$key] }
            $script:DiscoveryDocument.Matches = @($script:FirstMatch, $duplicate)
            $script:DiscoveryDocument | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:DiscoveryPath -Encoding UTF8
            { Read-InstalledAppDiscoveryData -Path $script:DiscoveryPath } |
                Should -Throw '*unique 64-character*'

            $script:FirstMatch.Evidence = @()
            $script:DiscoveryDocument.Matches = @($script:FirstMatch)
            $script:DiscoveryDocument | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:DiscoveryPath -Encoding UTF8
            { Read-InstalledAppDiscoveryData -Path $script:DiscoveryPath } |
                Should -Throw '*contains no evidence*'
        }

        It 'rejects untrusted evidence provenance and malformed structured commands' {
            $script:FirstMatch.Evidence[0].Source = 'UserOverride'
            $script:DiscoveryDocument | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:DiscoveryPath -Encoding UTF8
            { Read-InstalledAppDiscoveryData -Path $script:DiscoveryPath } |
                Should -Throw '*requires Registry*'

            $script:FirstMatch.Evidence[0].Source = 'Registry'
            $script:FirstMatch.Evidence[1].Value.ArgumentList = @(42)
            $script:DiscoveryDocument | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:DiscoveryPath -Encoding UTF8
            { Read-InstalledAppDiscoveryData -Path $script:DiscoveryPath } |
                Should -Throw '*non-string command argument*'

            $script:FirstMatch.Evidence[1].Value.ArgumentList = @('/S')
            $script:FirstMatch.Evidence[1].Value.Remove('ExpectedExitCodes')
            $script:DiscoveryDocument | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:DiscoveryPath -Encoding UTF8
            { Read-InstalledAppDiscoveryData -Path $script:DiscoveryPath } |
                Should -Throw '*no ExpectedExitCodes*'
        }
    }

    Describe 'New-PackageScaffold discovery selection' {

        BeforeEach {
            $script:ScaffoldInstaller = Join-Path $TestDrive 'setup.exe'
            $script:ScaffoldOutput    = Join-Path $TestDrive ('scaffold-{0}' -f [guid]::NewGuid().ToString('N'))
            Set-Content -LiteralPath $script:ScaffoldInstaller -Value 'synthetic installer' -Encoding UTF8

            $script:ImportedEvidence = [EvidenceRecord]::new(
                'UninstallCommand',
                [ordered] @{
                    Executable = '%ProgramFiles%\Acme App\uninstall.exe'
                    ArgumentList = @('/S')
                    ExpectedExitCodes = @(0)
                },
                [EvidenceSource]::DiscoveryJson,
                [ConfidenceLevel]::High,
                'Imported from reviewed discovery JSON match test (original source Registry).')
            $script:ImportedFinding = [Finding]::new(
                [FindingSeverity]::Warning,
                'INSTALLED_APP_REGISTRY_READ_FAILED',
                'One registry view could not be read.')

            Mock Read-InstalledAppDiscoveryData {
                [PSCustomObject] @{
                    PSTypeName = 'PSPackageForge.ProviderResult'
                    Provider   = 'DiscoveryJson'
                    MatchId    = 'selected-match'
                    Evidence   = @($script:ImportedEvidence)
                    Findings   = @($script:ImportedFinding)
                    Path       = $DiscoveryData
                }
            }
            Mock Get-InstallerInfo {
                param($Path, $AdditionalEvidence)

                $resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
                $info = [InstallerInfo]::new()
                $info.Path             = $resolved
                $info.FileName         = [System.IO.Path]::GetFileName($resolved)
                $info.SHA256           = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
                $info.Evidence         = @($AdditionalEvidence)
                $info.ResolvedEvidence = @($AdditionalEvidence)
                return $info
            }
            Mock Resolve-PackageSpec { return [PackageSpec]::new() }
            Mock Write-PackageManifest {
                param($InstallerInfo, $PackageSpec, $OutputPath)

                $null = $InstallerInfo
                $null = $PackageSpec
                Set-Content -LiteralPath $OutputPath -Value '{}' -Encoding UTF8
                return Get-Item -LiteralPath $OutputPath
            }
            Mock New-PackageDocument {
                param($ManifestPath)
                return [PSCustomObject] @{ DocumentPath = Join-Path (Split-Path $ManifestPath -Parent) 'PackageDocument.md' }
            }
            Mock Test-ScaffoldOutput { return @() }
        }

        It 'passes the requested match ID through and merges imported evidence before installer analysis' {
            $discoveryPath = Join-Path $TestDrive 'input.discovery.json'
            Set-Content -LiteralPath $discoveryPath -Value '{}' -Encoding UTF8
            $override = [EvidenceRecord]::new(
                'ProductName', 'Reviewed name', [EvidenceSource]::UserOverride, [ConfidenceLevel]::High)

            $result = New-PackageScaffold `
                -Path $script:ScaffoldInstaller `
                -OutputPath $script:ScaffoldOutput `
                -DiscoveryData $discoveryPath `
                -DiscoveryMatchId 'selected-match' `
                -AdditionalEvidence @($override)

            Should -Invoke Read-InstalledAppDiscoveryData -Times 1 -Exactly -ParameterFilter {
                $Path -eq $discoveryPath -and $MatchId -eq 'selected-match'
            }
            Should -Invoke Get-InstallerInfo -Times 1 -Exactly -ParameterFilter {
                @($AdditionalEvidence).Count -eq 2 -and
                @($AdditionalEvidence | Where-Object Source -eq ([EvidenceSource]::DiscoveryJson)).Count -eq 1 -and
                @($AdditionalEvidence | Where-Object Source -eq ([EvidenceSource]::UserOverride)).Count -eq 1
            }
            $result.DiscoveryMatchId | Should -Be 'selected-match'
            $result.InstallerInfo.Findings.Code | Should -Contain 'INSTALLED_APP_REGISTRY_READ_FAILED'
        }

        It 'rejects a match ID without discovery data before generating output' {
            {
                New-PackageScaffold `
                    -Path $script:ScaffoldInstaller `
                    -OutputPath $script:ScaffoldOutput `
                    -DiscoveryMatchId 'orphan-match'
            } | Should -Throw '*requires -DiscoveryData*'

            Should -Invoke Read-InstalledAppDiscoveryData -Times 0 -Exactly
            Test-Path -LiteralPath $script:ScaffoldOutput | Should -BeFalse
        }
    }
}

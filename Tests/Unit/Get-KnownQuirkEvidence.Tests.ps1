<#
    Unit tests for the known-quirk evidence provider (build order step 9).

    Every config here is synthetic and written to $TestDrive -- CI never depends on the
    real Config\known-quirks.psd1 shape for these tests, only on the matching/validation
    RULES, exactly the same reasoning Get-MsiEvidence.Tests.ps1 gives for using synthetic
    MsiDatabase objects instead of only the committed fixture.

    Evidence records are constructed inline in each test rather than through a shared
    helper function, matching Merge-InstallerEvidence.Tests.ps1: a helper function defined
    outside InModuleScope cannot see the module's classes (Windows PowerShell 5.1 class
    visibility is session-scoped -- see the psm1 module-load comment), and Pester 5 runs It
    blocks in their own scope, so inline construction is the idiom actually proven to work
    here rather than one more layer of scope to reason about.
#>

$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {

    Describe 'Get-KnownQuirkEvidence' {

        BeforeAll {
            # Identity evidence shaped like what Get-MsiEvidence would already have
            # gathered for a Firefox-ESR-like wrapper, before any quirk runs.
            $script:BaseIdentityEvidence = @(
                [EvidenceRecord]::new('ProductName',  'Mozilla Firefox 140.13.0esr x64 en-US',   [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                [EvidenceRecord]::new('Manufacturer', 'Mozilla',                                  [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                [EvidenceRecord]::new('UpgradeCode',  '{3118AB4C-B433-4FBB-B9FA-8F9CA4B5C103}',   [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                [EvidenceRecord]::new('ProductCode',  '{1294A4C5-9977-480F-9497-C0EA1E630130}',   [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
            )
        }

        Context 'Missing configuration' {

            It 'returns empty evidence and no findings when the config file does not exist' {
                $configPath = Join-Path $TestDrive 'does-not-exist.psd1'

                $result = Get-KnownQuirkEvidence -Evidence $script:BaseIdentityEvidence -ConfigPath $configPath

                $result.Evidence | Should -BeNullOrEmpty
                $result.Findings | Should -BeNullOrEmpty
            }
        }

        Context 'Malformed configuration' {

            It 'emits KNOWN_QUIRK_CONFIG_INVALID and empty evidence for a psd1 that fails to parse' {
                $configPath = Join-Path $TestDrive 'malformed.psd1'
                Set-Content -LiteralPath $configPath -Value '@{ SchemaVersion = "1.0"; Quirks = ( this is not valid data language @@@' -Encoding UTF8

                $result = Get-KnownQuirkEvidence -Evidence $script:BaseIdentityEvidence -ConfigPath $configPath

                $result.Evidence | Should -BeNullOrEmpty
                $finding = $result.Findings | Where-Object { $_.Code -eq 'KNOWN_QUIRK_CONFIG_INVALID' }
                $finding          | Should -Not -BeNullOrEmpty
                $finding.Severity | Should -Be ([FindingSeverity]::Warning)
            }

            It 'never throws for a malformed config -- fails loud via findings, not exceptions' {
                $configPath = Join-Path $TestDrive 'malformed2.psd1'
                Set-Content -LiteralPath $configPath -Value 'not even a hashtable' -Encoding UTF8

                { Get-KnownQuirkEvidence -Evidence $script:BaseIdentityEvidence -ConfigPath $configPath } | Should -Not -Throw
            }

            It 'emits KNOWN_QUIRK_CONFIG_INVALID for an unsupported SchemaVersion' {
                $configPath = Join-Path $TestDrive 'bad-schema.psd1'
                Set-Content -LiteralPath $configPath -Encoding UTF8 -Value @'
@{
    SchemaVersion = '99.0'
    Quirks = @()
}
'@

                $result = Get-KnownQuirkEvidence -Evidence $script:BaseIdentityEvidence -ConfigPath $configPath

                $result.Evidence | Should -BeNullOrEmpty
                ($result.Findings | Where-Object { $_.Code -eq 'KNOWN_QUIRK_CONFIG_INVALID' }) |
                    Should -Not -BeNullOrEmpty
            }
        }

        Context 'Matching' {

            BeforeAll {
                $script:MatchingConfigPath = Join-Path $TestDrive 'matching.psd1'
                Set-Content -LiteralPath $script:MatchingConfigPath -Encoding UTF8 -Value @'
@{
    SchemaVersion = '1.0'
    Quirks = @(
        @{
            Id = 'firefox-esr-msi-wrapper'
            Match = @{
                UpgradeCode         = '{3118AB4C-B433-4FBB-B9FA-8F9CA4B5C103}'
                ManufacturerPattern = '^Mozilla$'
                ProductNamePattern  = 'Firefox'
            }
            Evidence = @(
                @{ Field = 'InstallLocation'; Value = '%ProgramFiles%\Mozilla Firefox'; Confidence = 'Medium'; Notes = 'test' }
                @{ Field = 'DetectionTarget'; Value = '%ProgramFiles%\Mozilla Firefox\firefox.exe'; Confidence = 'Medium' }
                @{
                    Field = 'UninstallCommand'
                    Value = @{ Executable = '%ProgramFiles%\Mozilla Firefox\uninstall\helper.exe'; ArgumentList = @('/S'); ExpectedExitCodes = @(0) }
                    Confidence = 'Medium'
                }
            )
        }
    )
}
'@
            }

            It 'emits KnownQuirk-sourced evidence for every configured field when UpgradeCode and pattern keys all match' {
                $result = Get-KnownQuirkEvidence -Evidence $script:BaseIdentityEvidence -ConfigPath $script:MatchingConfigPath

                $result.Evidence.Count | Should -Be 3
                foreach ($record in $result.Evidence) {
                    $record.Source | Should -Be ([EvidenceSource]::KnownQuirk)
                }
                ($result.Evidence | Where-Object Field -eq 'InstallLocation').Value | Should -Be '%ProgramFiles%\Mozilla Firefox'
                ($result.Evidence | Where-Object Field -eq 'DetectionTarget').Value | Should -Be '%ProgramFiles%\Mozilla Firefox\firefox.exe'
            }

            It 'emits one KNOWN_QUIRK_APPLIED Info finding naming the quirk Id and its fields' {
                $result  = Get-KnownQuirkEvidence -Evidence $script:BaseIdentityEvidence -ConfigPath $script:MatchingConfigPath
                $finding = $result.Findings | Where-Object { $_.Code -eq 'KNOWN_QUIRK_APPLIED' }

                $finding          | Should -Not -BeNullOrEmpty
                $finding.Severity | Should -Be ([FindingSeverity]::Info)
                $finding.Message  | Should -BeLike '*firefox-esr-msi-wrapper*'
                $finding.Message  | Should -BeLike '*InstallLocation*'
            }

            It 'passes a hashtable-shaped command value through untouched' {
                $result = Get-KnownQuirkEvidence -Evidence $script:BaseIdentityEvidence -ConfigPath $script:MatchingConfigPath
                $record = $result.Evidence | Where-Object Field -eq 'UninstallCommand'

                $record.Value                       | Should -BeOfType [hashtable]
                $record.Value['Executable']          | Should -Be '%ProgramFiles%\Mozilla Firefox\uninstall\helper.exe'
                $record.Value['ArgumentList']        | Should -Be @('/S')
                $record.Value['ExpectedExitCodes']   | Should -Be @(0)
            }

            It 'emits nothing when the identity does not match' {
                $evidence = @(
                    [EvidenceRecord]::new('ProductName',  'Some Other Product',                        [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('Manufacturer', 'Some Other Vendor',                          [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('UpgradeCode',  '{00000000-0000-0000-0000-000000000000}',    [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('ProductCode',  '{00000000-0000-0000-0000-000000000001}',    [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                )

                $result = Get-KnownQuirkEvidence -Evidence $evidence -ConfigPath $script:MatchingConfigPath

                $result.Evidence | Should -BeNullOrEmpty
                $result.Findings | Should -BeNullOrEmpty
            }

            It 'ANDs pattern keys with the strong identifier -- a matching UpgradeCode alone is not enough' {
                # Right UpgradeCode, but a Manufacturer that does not satisfy ManufacturerPattern.
                $evidence = @(
                    [EvidenceRecord]::new('ProductName',  'Mozilla Firefox 140.13.0esr x64 en-US',   [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('Manufacturer', 'Not Mozilla At All',                       [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('UpgradeCode',  '{3118AB4C-B433-4FBB-B9FA-8F9CA4B5C103}',   [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('ProductCode',  '{1294A4C5-9977-480F-9497-C0EA1E630130}',   [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                )

                $result = Get-KnownQuirkEvidence -Evidence $evidence -ConfigPath $script:MatchingConfigPath

                $result.Evidence | Should -BeNullOrEmpty
                $result.Findings | Should -BeNullOrEmpty
            }

            It 'does not treat GUID brace/case differences in the identity as a non-match' {
                $evidence = @(
                    [EvidenceRecord]::new('ProductName',  'Mozilla Firefox 140.13.0esr x64 en-US', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('Manufacturer', 'Mozilla',                                [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('UpgradeCode',  '3118ab4c-b433-4fbb-b9fa-8f9ca4b5c103',   [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('ProductCode',  '{1294A4C5-9977-480F-9497-C0EA1E630130}', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                )

                $result = Get-KnownQuirkEvidence -Evidence $evidence -ConfigPath $script:MatchingConfigPath

                $result.Evidence | Should -Not -BeNullOrEmpty
            }
        }

        Context 'Invalid confidence' {

            BeforeAll {
                $script:BadConfidenceConfigPath = Join-Path $TestDrive 'bad-confidence.psd1'
                Set-Content -LiteralPath $script:BadConfidenceConfigPath -Encoding UTF8 -Value @'
@{
    SchemaVersion = '1.0'
    Quirks = @(
        @{
            Id = 'bad-confidence-quirk'
            Match = @{ UpgradeCode = '{3118AB4C-B433-4FBB-B9FA-8F9CA4B5C103}' }
            Evidence = @(
                @{ Field = 'InstallLocation'; Value = 'C:\Somewhere'; Confidence = 'Extreme' }
            )
        }
    )
}
'@
            }

            It 'falls back to Low and emits a KNOWN_QUIRK_CONFIG_INVALID warning naming the bad value' {
                $result = Get-KnownQuirkEvidence -Evidence $script:BaseIdentityEvidence -ConfigPath $script:BadConfidenceConfigPath

                $record = $result.Evidence | Where-Object Field -eq 'InstallLocation'
                $record.Confidence | Should -Be ([ConfidenceLevel]::Low)

                $finding = $result.Findings | Where-Object { $_.Code -eq 'KNOWN_QUIRK_CONFIG_INVALID' }
                $finding          | Should -Not -BeNullOrEmpty
                $finding.Severity | Should -Be ([FindingSeverity]::Warning)
                $finding.Message  | Should -BeLike '*Extreme*'
            }
        }

        Context 'Quirk without a strong identifier' {

            BeforeAll {
                $script:NoIdentifierConfigPath = Join-Path $TestDrive 'no-identifier.psd1'
                Set-Content -LiteralPath $script:NoIdentifierConfigPath -Encoding UTF8 -Value @'
@{
    SchemaVersion = '1.0'
    Quirks = @(
        @{
            Id = 'no-strong-identifier'
            Match = @{ ManufacturerPattern = '^Mozilla$' }
            Evidence = @(
                @{ Field = 'InstallLocation'; Value = 'C:\Somewhere'; Confidence = 'Medium' }
            )
        }
    )
}
'@
            }

            It 'is skipped and reported via KNOWN_QUIRK_CONFIG_INVALID rather than matched' {
                $result = Get-KnownQuirkEvidence -Evidence $script:BaseIdentityEvidence -ConfigPath $script:NoIdentifierConfigPath

                $result.Evidence | Should -BeNullOrEmpty
                $finding = $result.Findings | Where-Object { $_.Code -eq 'KNOWN_QUIRK_CONFIG_INVALID' }
                $finding          | Should -Not -BeNullOrEmpty
                $finding.Message  | Should -BeLike '*no-strong-identifier*'
            }
        }

        Context 'End-to-end precedence through the merger' {

            BeforeAll {
                $script:PrecedenceConfigPath = Join-Path $TestDrive 'precedence.psd1'
                Set-Content -LiteralPath $script:PrecedenceConfigPath -Encoding UTF8 -Value @'
@{
    SchemaVersion = '1.0'
    Quirks = @(
        @{
            Id = 'precedence-quirk'
            Match = @{ UpgradeCode = '{3118AB4C-B433-4FBB-B9FA-8F9CA4B5C103}' }
            Evidence = @(
                @{ Field = 'InstallLocation'; Value = 'C:\FromQuirk'; Confidence = 'Medium' }
            )
        }
    )
}
'@
            }

            It 'loses to a real MsiDatabase InstallLocation observation' {
                $quirk = Get-KnownQuirkEvidence -Evidence $script:BaseIdentityEvidence -ConfigPath $script:PrecedenceConfigPath

                $allEvidence = @($script:BaseIdentityEvidence) + @(
                    [EvidenceRecord]::new('InstallLocation', 'C:\FromMsi', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                ) + @($quirk.Evidence)

                $merge = Merge-InstallerEvidence -Evidence $allEvidence

                $merge.Resolved['InstallLocation'].Value  | Should -Be 'C:\FromMsi'
                $merge.Resolved['InstallLocation'].Source | Should -Be ([EvidenceSource]::MsiDatabase)
            }

            It 'survives to become the resolved winner when the MSI provider emitted no InstallLocation' {
                $quirk = Get-KnownQuirkEvidence -Evidence $script:BaseIdentityEvidence -ConfigPath $script:PrecedenceConfigPath

                # No MsiDatabase InstallLocation record at all -- the refusal case.
                $allEvidence = @($script:BaseIdentityEvidence) + @($quirk.Evidence)

                $merge = Merge-InstallerEvidence -Evidence $allEvidence

                $merge.Resolved['InstallLocation'].Value  | Should -Be 'C:\FromQuirk'
                $merge.Resolved['InstallLocation'].Source | Should -Be ([EvidenceSource]::KnownQuirk)
            }
        }
    }
}

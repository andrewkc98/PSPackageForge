<#
    Unit tests for the evidence merger (plan §5.3).

    These were written before any provider existed, on purpose: the merger is the seam
    that decides what the whole tool believes, and it needs to be correct independently of
    where the evidence came from.

    InModuleScope is used rather than `using module` so that the module's classes are
    visible without the assembly-caching behaviour that makes `using module` require a
    fresh PowerShell session after every class edit.
#>

$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {

    Describe 'Merge-InstallerEvidence' {

        Context 'Precedence' {

            It 'resolves a field to the highest-precedence source regardless of input order' {
                $evidence = @(
                    [EvidenceRecord]::new('ProductName', 'From PE', [EvidenceSource]::PeMetadata, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('ProductName', 'From MSI', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('ProductName', 'From quirk', [EvidenceSource]::KnownQuirk, [ConfidenceLevel]::High)
                )

                $result = Merge-InstallerEvidence -Evidence $evidence

                $result.Resolved['ProductName'].Value  | Should -Be 'From MSI'
                $result.Resolved['ProductName'].Source | Should -Be ([EvidenceSource]::MsiDatabase)
            }

            It 'honours the full documented precedence chain from plan 5.3' {
                # Highest first. Each pair asserts that the left source beats the right.
                $chain = @(
                    [EvidenceSource]::UserOverride
                    [EvidenceSource]::DiscoveryJson
                    [EvidenceSource]::Registry
                    [EvidenceSource]::MsiDatabase
                    [EvidenceSource]::KnownQuirk
                    [EvidenceSource]::PeMetadata
                    [EvidenceSource]::Inferred
                )

                for ($i = 0; $i -lt $chain.Count - 1; $i++) {
                    $higher = $chain[$i]
                    $lower  = $chain[$i + 1]

                    $evidence = @(
                        [EvidenceRecord]::new('InstallLocation', "value-$lower", $lower, [ConfidenceLevel]::High)
                        [EvidenceRecord]::new('InstallLocation', "value-$higher", $higher, [ConfidenceLevel]::High)
                    )

                    $result = Merge-InstallerEvidence -Evidence $evidence
                    $result.Resolved['InstallLocation'].Source | Should -Be $higher -Because "$higher outranks $lower"
                }
            }

            It 'breaks a precedence tie using confidence' {
                $evidence = @(
                    [EvidenceRecord]::new('Architecture', 'x86', [EvidenceSource]::PeMetadata, [ConfidenceLevel]::Low)
                    [EvidenceRecord]::new('Architecture', 'x64', [EvidenceSource]::PeMetadata, [ConfidenceLevel]::High)
                )

                $result = Merge-InstallerEvidence -Evidence $evidence

                $result.Resolved['Architecture'].Value | Should -Be 'x64'
            }

            It 'breaks a precedence and confidence tie using input order, deterministically' {
                $evidence = @(
                    [EvidenceRecord]::new('Language', '1033', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('Language', '2057', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                )

                # Run twice; a stable sort must give the same answer both times.
                $first  = Merge-InstallerEvidence -Evidence $evidence
                $second = Merge-InstallerEvidence -Evidence $evidence

                $first.Resolved['Language'].Value  | Should -Be '1033'
                $second.Resolved['Language'].Value | Should -Be '1033'
            }
        }

        Context 'Per-field provenance' {

            It 'keeps provenance per field, not per package' {
                $evidence = @(
                    [EvidenceRecord]::new('ProductCode', '{11111111-1111-1111-1111-111111111111}', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('InstallLocation', 'C:\Program Files\Mozilla Firefox', [EvidenceSource]::KnownQuirk, [ConfidenceLevel]::Medium)
                    [EvidenceRecord]::new('Framework', 'Nsis', [EvidenceSource]::PeMetadata, [ConfidenceLevel]::High)
                )

                $result = Merge-InstallerEvidence -Evidence $evidence

                # This is the Firefox honesty requirement in miniature: a path supplied by
                # a quirk must never end up attributed to the MSI database.
                $result.Resolved['ProductCode'].Source     | Should -Be ([EvidenceSource]::MsiDatabase)
                $result.Resolved['InstallLocation'].Source | Should -Be ([EvidenceSource]::KnownQuirk)
                $result.Resolved['Framework'].Source       | Should -Be ([EvidenceSource]::PeMetadata)
            }

            It 'preserves first-seen field order so manifests are stable between runs' {
                $evidence = @(
                    [EvidenceRecord]::new('Zulu', 'z', [EvidenceSource]::Inferred, [ConfidenceLevel]::Low)
                    [EvidenceRecord]::new('Alpha', 'a', [EvidenceSource]::Inferred, [ConfidenceLevel]::Low)
                    [EvidenceRecord]::new('Zulu', 'z2', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::Low)
                )

                $result = Merge-InstallerEvidence -Evidence $evidence

                @($result.Resolved.Keys) | Should -Be @('Zulu', 'Alpha')
            }
        }

        Context 'High-confidence conflict on a critical field' {

            BeforeEach {
                $script:conflicting = @(
                    [EvidenceRecord]::new('InstallLocation', 'C:\Program Files\KiCad\8.0', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('InstallLocation', 'C:\Program Files\KiCad\9.0', [EvidenceSource]::DiscoveryJson, [ConfidenceLevel]::High)
                )
            }

            It 'still applies precedence' {
                $result = Merge-InstallerEvidence -Evidence $script:conflicting
                $result.Resolved['InstallLocation'].Value | Should -Be 'C:\Program Files\KiCad\9.0'
            }

            It 'downgrades the winning field to Medium' {
                $result = Merge-InstallerEvidence -Evidence $script:conflicting
                $result.Resolved['InstallLocation'].Confidence | Should -Be ([ConfidenceLevel]::Medium)
            }

            It 'emits an EVIDENCE_CONFLICT Warning naming the field' {
                $result = Merge-InstallerEvidence -Evidence $script:conflicting

                $finding = $result.Findings | Where-Object { $_.Code -eq 'EVIDENCE_CONFLICT' }
                $finding                  | Should -Not -BeNullOrEmpty
                $finding.Severity         | Should -Be ([FindingSeverity]::Warning)
                $finding.Field            | Should -Be 'InstallLocation'
            }

            It 'reports both losing and winning values in the finding message' {
                $result  = Merge-InstallerEvidence -Evidence $script:conflicting
                $finding = $result.Findings | Where-Object { $_.Code -eq 'EVIDENCE_CONFLICT' }

                # An operator cannot adjudicate a conflict they cannot see.
                $finding.Message | Should -BeLike '*KiCad\8.0*'
                $finding.Message | Should -BeLike '*KiCad\9.0*'
            }

            It 'never mutates the records the provider emitted' {
                $null = Merge-InstallerEvidence -Evidence $script:conflicting

                # The audit trail must still say what each provider actually observed.
                $script:conflicting[0].Confidence | Should -Be ([ConfidenceLevel]::High)
                $script:conflicting[1].Confidence | Should -Be ([ConfidenceLevel]::High)
            }

            It 'lists the field in Conflicts' {
                $result = Merge-InstallerEvidence -Evidence $script:conflicting
                $result.Conflicts | Should -Contain 'InstallLocation'
            }

            It 'treats every critical field named in plan 5.3 as critical' {
                foreach ($field in @('InstallCommand', 'UninstallCommand', 'InstallLocation', 'SelectedContext', 'DetectionTarget')) {
                    $evidence = @(
                        [EvidenceRecord]::new($field, 'left', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                        [EvidenceRecord]::new($field, 'right', [EvidenceSource]::DiscoveryJson, [ConfidenceLevel]::High)
                    )

                    $result  = Merge-InstallerEvidence -Evidence $evidence
                    $finding = $result.Findings | Where-Object { $_.Code -eq 'EVIDENCE_CONFLICT' }

                    $finding.Severity                     | Should -Be ([FindingSeverity]::Warning) -Because "$field is critical"
                    $result.Resolved[$field].Confidence   | Should -Be ([ConfidenceLevel]::Medium) -Because "$field is critical"
                }
            }
        }

        Context 'High-confidence conflict on a non-critical field' {

            It 'surfaces the disagreement as Info without downgrading confidence' {
                $evidence = @(
                    [EvidenceRecord]::new('Manufacturer', 'Igor Pavlov', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('Manufacturer', '7-Zip', [EvidenceSource]::DiscoveryJson, [ConfidenceLevel]::High)
                )

                $result  = Merge-InstallerEvidence -Evidence $evidence
                $finding = $result.Findings | Where-Object { $_.Code -eq 'EVIDENCE_CONFLICT' }

                $finding.Severity                        | Should -Be ([FindingSeverity]::Info)
                $result.Resolved['Manufacturer'].Confidence | Should -Be ([ConfidenceLevel]::High)
            }
        }

        Context 'What is NOT a conflict' {

            It 'treats agreement between two high-confidence sources as corroboration' {
                $evidence = @(
                    [EvidenceRecord]::new('InstallLocation', 'C:\Program Files\7-Zip', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('InstallLocation', 'C:\Program Files\7-Zip', [EvidenceSource]::DiscoveryJson, [ConfidenceLevel]::High)
                )

                $result = Merge-InstallerEvidence -Evidence $evidence

                $result.Findings  | Should -BeNullOrEmpty
                $result.Conflicts | Should -BeNullOrEmpty
            }

            It 'does not treat GUID case or bracket differences as a disagreement' {
                $evidence = @(
                    [EvidenceRecord]::new('ProductCode', '{b67274a8-a56d-4c2e-b1a0-7a59f5433bd2}', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('ProductCode', 'B67274A8-A56D-4C2E-B1A0-7A59F5433BD2', [EvidenceSource]::DiscoveryJson, [ConfidenceLevel]::High)
                )

                $result = Merge-InstallerEvidence -Evidence $evidence
                $result.Conflicts | Should -BeNullOrEmpty
            }

            It 'does not treat a trailing path separator as a disagreement' {
                $evidence = @(
                    [EvidenceRecord]::new('InstallLocation', 'C:\Program Files\7-Zip\', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('InstallLocation', 'C:\Program Files\7-Zip', [EvidenceSource]::DiscoveryJson, [ConfidenceLevel]::High)
                )

                $result = Merge-InstallerEvidence -Evidence $evidence
                $result.Conflicts | Should -BeNullOrEmpty
            }

            It 'does NOT collapse differing version padding, because that is a real difference' {
                # Plan §7.3: '1.0' and '1.0.0.0' are different facts. Hiding the difference
                # would hide the padding question the plan says to surface.
                $evidence = @(
                    [EvidenceRecord]::new('DetectionTarget', '1.0', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('DetectionTarget', '1.0.0.0', [EvidenceSource]::DiscoveryJson, [ConfidenceLevel]::High)
                )

                $result = Merge-InstallerEvidence -Evidence $evidence
                $result.Conflicts | Should -Contain 'DetectionTarget'
            }

            It 'does not raise a conflict when the disagreeing sources are not both High' {
                $evidence = @(
                    [EvidenceRecord]::new('InstallLocation', 'C:\Left', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('InstallLocation', 'C:\Right', [EvidenceSource]::DiscoveryJson, [ConfidenceLevel]::Medium)
                )

                $result = Merge-InstallerEvidence -Evidence $evidence

                # Medium losing to High is ordinary resolution, not a conflict -- but
                # precedence still wins, so DiscoveryJson takes it.
                $result.Conflicts                           | Should -BeNullOrEmpty
                $result.Resolved['InstallLocation'].Value   | Should -Be 'C:\Right'
            }
        }

        Context 'Edge cases' {

            It 'accepts an empty evidence collection' {
                $result = Merge-InstallerEvidence -Evidence @()

                $result.Resolved.Count | Should -Be 0
                $result.Findings       | Should -BeNullOrEmpty
            }

            It 'accepts evidence from the pipeline' {
                $evidence = @(
                    [EvidenceRecord]::new('ProductName', 'A', [EvidenceSource]::PeMetadata, [ConfidenceLevel]::Medium)
                    [EvidenceRecord]::new('ProductName', 'B', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::Medium)
                )

                $result = $evidence | Merge-InstallerEvidence

                $result.Resolved['ProductName'].Value | Should -Be 'B'
            }

            It 'compares array values element-wise and in order' {
                $evidence = @(
                    [EvidenceRecord]::new('InstallCommand', @('/qn', '/norestart'), [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
                    [EvidenceRecord]::new('InstallCommand', @('/norestart', '/qn'), [EvidenceSource]::DiscoveryJson, [ConfidenceLevel]::High)
                )

                $result = Merge-InstallerEvidence -Evidence $evidence

                # Argument order matters to an installer, so it matters to the comparison.
                $result.Conflicts | Should -Contain 'InstallCommand'
            }
        }
    }

    Describe 'ConvertTo-ForgeComparableValue' {

        It 'canonicalises <Description>' -ForEach @(
            @{ Description = 'null';            Left = $null;      Right = $null;       Same = $true }
            @{ Description = 'mixed-case text'; Left = 'Firefox';  Right = 'firefox';   Same = $true }
            @{ Description = 'padded text';     Left = ' 7-Zip ';  Right = '7-Zip';     Same = $true }
            @{ Description = 'booleans';        Left = $true;      Right = $true;       Same = $true }
            @{ Description = 'differing text';  Left = 'Firefox';  Right = 'Chrome';    Same = $false }
        ) {
            $a = ConvertTo-ForgeComparableValue -Value $Left
            $b = ConvertTo-ForgeComparableValue -Value $Right

            if ($Same) { $a | Should -Be $b } else { $a | Should -Not -Be $b }
        }
    }
}

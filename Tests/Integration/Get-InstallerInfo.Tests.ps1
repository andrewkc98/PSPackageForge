<#
    Public-boundary coverage for Get-InstallerInfo. The command is deliberately invoked
    outside InModuleScope so these assertions exercise the object a real caller receives.
#>

Describe 'Get-InstallerInfo public boundary' {

    BeforeAll {
        $script:ModuleRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:ManifestPath = Join-Path $script:ModuleRoot 'PSPackageForge.psd1'
        $script:FixturePath  = Join-Path $script:ModuleRoot 'Tests\Fixtures\native-clean.msi'
        Import-Module $script:ManifestPath -Force
    }

    It 'returns native MSI identity through the exported command' {
        $result = Get-InstallerInfo -Path $script:FixturePath

        $result.GetType().Name       | Should -Be 'InstallerInfo'
        $result.ContainerType        | Should -Be 'Msi'
        $result.MsiKind              | Should -Be 'Native'
        $result.ProductName          | Should -Be 'Fixture Native'
        $result.ProductCodePresent   | Should -BeTrue
        $result.SupportsMsiUninstall | Should -BeTrue
    }

    It 'preserves both raw sides of a conflict and exposes the resolved winner separately' {
        $override = & (Get-Module PSPackageForge) {
            [EvidenceRecord]::new(
                'InstallLocation',
                'C:\Program Files\ReviewedFixture',
                [EvidenceSource]::UserOverride,
                [ConfidenceLevel]::High,
                'Reviewed operator override.')
        }

        $result   = Get-InstallerInfo -Path $script:FixturePath -AdditionalEvidence $override
        $raw      = @($result.GetRawEvidence('InstallLocation'))
        $resolved = $result.GetResolvedEvidence('InstallLocation')

        $raw.Count                              | Should -Be 2
        $raw.Value                              | Should -Contain '%ProgramFiles(x86)%\FixtureNative'
        $raw.Value                              | Should -Contain 'C:\Program Files\ReviewedFixture'
        $raw.Confidence                         | Should -Be @('High', 'High')
        $resolved.Value                         | Should -Be 'C:\Program Files\ReviewedFixture'
        $resolved.Source                        | Should -Be 'UserOverride'
        $resolved.Confidence                    | Should -Be 'Medium'
        $result.GetEvidence('InstallLocation')  | Should -Be $resolved
        ($result.Findings | Where-Object Code -eq 'EVIDENCE_CONFLICT') | Should -Not -BeNullOrEmpty
    }

    It 'serializes raw and resolved evidence as distinct collections' {
        $result = Get-InstallerInfo -Path $script:FixturePath
        $dict   = $result.ToOrderedDictionary()
        $json   = $dict | ConvertTo-Json -Depth 12

        $dict.Evidence.Count         | Should -BeGreaterThan 0
        $dict.ResolvedEvidence.Count | Should -BeGreaterThan 0
        $json                        | Should -Match '"Evidence"'
        $json                        | Should -Match '"ResolvedEvidence"'
        $dict.Signature.Contains('TimestampUtc') | Should -BeFalse
    }

    It 'reports an extension mismatch while trusting the container signature' {
        $renamed = Join-Path $TestDrive 'renamed-installer.exe'
        Copy-Item -LiteralPath $script:FixturePath -Destination $renamed

        $result = Get-InstallerInfo -Path $renamed

        $result.ContainerType | Should -Be 'Msi'
        ($result.Findings | Where-Object Code -eq 'CONTAINER_EXTENSION_MISMATCH') |
            Should -Not -BeNullOrEmpty
    }

    It 'returns a controlled finding when an MSI container cannot be read' {
        $broken = Join-Path $TestDrive 'broken.msi'
        [System.IO.File]::WriteAllBytes($broken, [byte[]] @(
            0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))

        $result = Get-InstallerInfo -Path $broken

        $result.ContainerType | Should -Be 'Msi'
        ($result.Findings | Where-Object Code -eq 'MSI_READ_FAILED') |
            Should -Not -BeNullOrEmpty
    }

    It 'does not leave the installer locked after the public command returns' {
        $null = Get-InstallerInfo -Path $script:FixturePath

        { [System.IO.File]::Open($script:FixturePath, 'Open', 'Read', 'None').Dispose() } |
            Should -Not -Throw
    }
}

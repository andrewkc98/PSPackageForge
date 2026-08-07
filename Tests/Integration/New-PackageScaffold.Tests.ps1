<# Public orchestration boundary for the core manifest/detection milestone. #>

Describe 'New-PackageScaffold core output' {

    BeforeAll {
        $script:ModuleRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:ManifestPath = Join-Path $script:ModuleRoot 'PSPackageForge.psd1'
        $script:FixturePath  = Join-Path $script:ModuleRoot 'Tests\Fixtures\native-clean.msi'
        Import-Module $script:ManifestPath -Force
    }

    It 'writes the authoritative manifest and a detection script from one PackageSpec' {
        $context = & (Get-Module PSPackageForge) {
            [EvidenceRecord]::new(
                'SelectedContext', 'System', [EvidenceSource]::UserOverride,
                [ConfidenceLevel]::High, 'Integration-test deployment decision.')
        }
        $outputPath = Join-Path $TestDrive 'scaffold'

        $result = New-PackageScaffold -Path $script:FixturePath -OutputPath $outputPath -AdditionalEvidence $context

        $result.GetType().Name | Should -Be 'PSCustomObject'
        $result.Readiness      | Should -Be 'ReviewRequired'
        $result.ManifestPath   | Should -Exist
        $result.DetectionPath  | Should -Exist
        $result.InstallerPath  | Should -Exist
        (Get-FileHash $result.InstallerPath -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash $script:FixturePath -Algorithm SHA256).Hash

        $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json
        $manifest.Readiness                        | Should -Be 'ReviewRequired'
        $manifest.PackageSpec.DetectionSpec.Count  | Should -Be 1
        $manifest.Installer.SHA256                 | Should -Be (Get-FileHash $script:FixturePath -Algorithm SHA256).Hash
    }

    It 'always writes a manifest before FailOnLowConfidence stops automation' {
        $outputPath = Join-Path $TestDrive 'blocked-scaffold'
        $lowTarget = & (Get-Module PSPackageForge) {
            [EvidenceRecord]::new(
                'DetectionTarget', 'C:\Unverified\app.exe', [EvidenceSource]::UserOverride,
                [ConfidenceLevel]::Low, 'Unverified target for blocking-path coverage.')
        }

        { New-PackageScaffold -Path $script:FixturePath -OutputPath $outputPath `
                -AdditionalEvidence $lowTarget -FailOnLowConfidence } |
            Should -Throw '*NeedsInput*'

        (Join-Path $outputPath 'PackageManifest.json') | Should -Exist
        (Join-Path $outputPath 'Detect-Application.ps1') | Should -Not -Exist
    }
}

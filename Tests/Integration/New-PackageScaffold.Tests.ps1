<# Public orchestration boundary for the core manifest/detection milestone. #>

Describe 'New-PackageScaffold core output' `
    -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {

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

Describe 'New-PackageScaffold schema-2 EXE output' {
    BeforeAll {
        $script:ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:ManifestPath = Join-Path $script:ModuleRoot 'PSPackageForge.psd1'
        $script:ExeFixturePath = Join-Path $script:ModuleRoot 'Tests\Fixtures\framework-stubs\wix-burn.exe'
        Import-Module $script:ManifestPath -Force

        # The document renderer is covered by the Windows-only integration boundary above.
        # Keep this public scaffold contract portable: EXE evidence, manifest emission, and
        # the pre-package self-check do not require Windows document rendering.
        if ($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {
            Mock New-PackageDocument -ModuleName PSPackageForge {
                [PSCustomObject] @{ DocumentPath = $null }
            }
        }
    }

    It 'round-trips a generated scaffold with both schema-2 architecture subjects' {
        $outputPath = Join-Path $TestDrive 'exe-scaffold'

        $result = New-PackageScaffold -Path $script:ExeFixturePath -OutputPath $outputPath

        $result.ManifestPath | Should -Exist
        $result.InstallerPath | Should -Exist
        $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json

        $manifest.SchemaVersion | Should -Be '2.0'
        $manifest.Installer.InstallerArchitecture | Should -Be 'x64'
        $manifest.Installer.ApplicationArchitecture | Should -Be 'Unknown'
        $manifest.Installer.PSObject.Properties.Name | Should -Not -Contain 'Architecture'
        $manifest.PackageSpec.SchemaVersion | Should -Be '2.0'
        (Join-Path $outputPath 'PackageReceipt.json') | Should -Not -Exist
    }

    It 'reports SCAFFOLD_HASH_MISMATCH when the generated installer is tampered with' {
        $outputPath = Join-Path $TestDrive 'exe-tampered'
        $result = New-PackageScaffold -Path $script:ExeFixturePath -OutputPath $outputPath

        Add-Content -LiteralPath $result.InstallerPath -Value 'tampered' -NoNewline
        $findings = & (Get-Module PSPackageForge) {
            param($scaffoldOutputPath, $scaffoldManifestPath)
            @(Test-ScaffoldOutput -OutputPath $scaffoldOutputPath -ManifestPath $scaffoldManifestPath)
        } $outputPath $result.ManifestPath

        $findings.Code | Should -Contain 'SCAFFOLD_HASH_MISMATCH'
        $findings | Where-Object Code -eq 'SCAFFOLD_HASH_MISMATCH' | ForEach-Object {
            $_.Severity.ToString() | Should -Be 'Blocking'
        }
    }
}

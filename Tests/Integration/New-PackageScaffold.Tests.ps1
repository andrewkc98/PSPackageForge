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

Describe 'New-PackageScaffold unconfirmed file version finding' `
    -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {

    BeforeAll {
        $script:ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:ManifestPath = Join-Path $script:ModuleRoot 'PSPackageForge.psd1'
        $script:ExeFixturePath = Join-Path $script:ModuleRoot 'Tests\Fixtures\framework-stubs\wix-burn.exe'
        $script:MsiFixturePath = Join-Path $script:ModuleRoot 'Tests\Fixtures\native-clean.msi'
        Import-Module $script:ManifestPath -Force
    }

    It 'adds one warning and explains that only file existence was checked when the expected version is absent' {
        $target = & (Get-Module PSPackageForge) {
            [EvidenceRecord]::new('DetectionTarget', 'C:\Program Files\Example\app.exe',
                [EvidenceSource]::UserOverride, [ConfidenceLevel]::High, 'Reviewed test target.')
        }
        $context = & (Get-Module PSPackageForge) {
            [EvidenceRecord]::new('SelectedContext', 'System',
                [EvidenceSource]::UserOverride, [ConfidenceLevel]::High, 'Reviewed test context.')
        }
        $commands = & (Get-Module PSPackageForge) {
            $install = [CommandSpec]::new('setup.exe', @('/S'))
            $uninstall = [CommandSpec]::new('uninstall.exe', @('/S'))
            @(
                [EvidenceRecord]::new('InstallCommand', $install, [EvidenceSource]::UserOverride,
                    [ConfidenceLevel]::High, 'Reviewed test install command.'),
                [EvidenceRecord]::new('UninstallCommand', $uninstall, [EvidenceSource]::UserOverride,
                    [ConfidenceLevel]::High, 'Reviewed test uninstall command.')
            )
        }
        $outputPath = Join-Path $TestDrive 'missing-version'

        $result = New-PackageScaffold -Path $script:ExeFixturePath -OutputPath $outputPath `
            -AdditionalEvidence (@($target, $context) + $commands)
        $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json
        $finding = @($manifest.Findings | Where-Object {
            $_.Code -eq 'DETECTION_VERSION_UNCONFIRMED' -and $_.Field -eq 'DetectionTargetVersion'
        })

        $finding.Count | Should -Be 1
        $finding[0].Severity | Should -Be 'Warning'
        $result.Readiness | Should -Be 'ReviewRequired'
        $manifest.PackageSpec.DetectionSpec[0].Operator | Should -Be 'Exists'
        $manifest.PackageSpec.DetectionSpec[0].Rationale | Should -Match 'Only file existence was checked'
        $manifest.PackageSpec.DetectionSpec[0].Rationale | Should -Match 'version is unconfirmed'
        $result.DetectionPath | Should -Exist
        (Get-Content -LiteralPath $result.DetectionPath -Raw) | Should -Match 'Write-Output "Detected:'
        (Get-Content -LiteralPath $result.DocumentPath -Raw) | Should -Match 'Only file existence was checked'
    }

    It 'does not append a duplicate warning with the same code and field' {
        $target = & (Get-Module PSPackageForge) {
            [EvidenceRecord]::new('DetectionTarget', 'C:\Program Files\Example\app.exe',
                [EvidenceSource]::UserOverride, [ConfidenceLevel]::High, 'Reviewed test target.')
        }
        $context = & (Get-Module PSPackageForge) {
            [EvidenceRecord]::new('SelectedContext', 'System',
                [EvidenceSource]::UserOverride, [ConfidenceLevel]::High, 'Reviewed test context.')
        }
        $commands = & (Get-Module PSPackageForge) {
            $install = [CommandSpec]::new('setup.exe', @('/S'))
            $uninstall = [CommandSpec]::new('uninstall.exe', @('/S'))
            @(
                [EvidenceRecord]::new('InstallCommand', $install, [EvidenceSource]::UserOverride,
                    [ConfidenceLevel]::High, 'Reviewed test install command.'),
                [EvidenceRecord]::new('UninstallCommand', $uninstall, [EvidenceSource]::UserOverride,
                    [ConfidenceLevel]::High, 'Reviewed test uninstall command.')
            )
        }
        $script:PreexistingWarning = & (Get-Module PSPackageForge) {
            New-ForgeFinding -Severity Warning -Code 'DETECTION_VERSION_UNCONFIRMED' `
                -Field 'DetectionTargetVersion' -Message 'Previously reported by the provider.'
        }
        $script:InstallerInfoWithWarning = Get-InstallerInfo -Path $script:ExeFixturePath `
            -AdditionalEvidence (@($target, $context) + $commands)
        $script:InstallerInfoWithWarning.Findings = @($script:InstallerInfoWithWarning.Findings) + $script:PreexistingWarning
        Mock Get-InstallerInfo -ModuleName PSPackageForge { $script:InstallerInfoWithWarning }
        $outputPath = Join-Path $TestDrive 'duplicate-warning'

        $result = New-PackageScaffold -Path $script:ExeFixturePath -OutputPath $outputPath `
            -AdditionalEvidence (@($target, $context) + $commands)
        $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json

        @($manifest.Findings | Where-Object {
            $_.Code -eq 'DETECTION_VERSION_UNCONFIRMED' -and $_.Field -eq 'DetectionTargetVersion'
        }).Count | Should -Be 1
    }

    It 'does not report an unconfirmed file version when detection falls back to an MSI product code' {
        $context = & (Get-Module PSPackageForge) {
            [EvidenceRecord]::new('SelectedContext', 'System',
                [EvidenceSource]::UserOverride, [ConfidenceLevel]::High, 'Reviewed test context.')
        }
        $script:InstallerInfoForMsiFallback = & (Get-Module PSPackageForge) {
            param($filePath, $selectedContext)
            $resolvedPath = (Resolve-Path -LiteralPath $filePath).ProviderPath
            $info = [InstallerInfo]::new()
            $info.Path = $resolvedPath
            $info.FileName = [System.IO.Path]::GetFileName($resolvedPath)
            $info.SHA256 = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash
            $info.ContainerType = [ContainerType]::Msi
            $info.ProductCode = '{11111111-1111-1111-1111-111111111111}'
            $info.ProductCodePresent = $true
            $info.SupportsMsiUninstall = $true
            $info.Evidence = @($selectedContext)
            $info.ResolvedEvidence = @($selectedContext)
            $info
        } $script:MsiFixturePath $context
        Mock Get-InstallerInfo -ModuleName PSPackageForge { $script:InstallerInfoForMsiFallback }
        $result = New-PackageScaffold -Path $script:MsiFixturePath `
            -OutputPath (Join-Path $TestDrive 'msi-fallback') -AdditionalEvidence $context
        $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json

        @($manifest.Findings | Where-Object Code -eq 'DETECTION_VERSION_UNCONFIRMED').Count | Should -Be 0
        $manifest.PackageSpec.DetectionSpec[0].Kind | Should -Be 'MsiProductCode'
    }

    It 'keeps malformed expected versions on the existing low-confidence NeedsInput path without the missing-version warning' {
        $target = & (Get-Module PSPackageForge) {
            [EvidenceRecord]::new('DetectionTarget', 'C:\Program Files\Example\app.exe',
                [EvidenceSource]::UserOverride, [ConfidenceLevel]::High, 'Reviewed test target.')
        }
        $version = & (Get-Module PSPackageForge) {
            [EvidenceRecord]::new('DetectionTargetVersion', '26.02 beta',
                [EvidenceSource]::UserOverride, [ConfidenceLevel]::High, 'Malformed test version.')
        }
        $context = & (Get-Module PSPackageForge) {
            [EvidenceRecord]::new('SelectedContext', 'System',
                [EvidenceSource]::UserOverride, [ConfidenceLevel]::High, 'Reviewed test context.')
        }
        $commands = & (Get-Module PSPackageForge) {
            $install = [CommandSpec]::new('setup.exe', @('/S'))
            $uninstall = [CommandSpec]::new('uninstall.exe', @('/S'))
            @(
                [EvidenceRecord]::new('InstallCommand', $install, [EvidenceSource]::UserOverride,
                    [ConfidenceLevel]::High, 'Reviewed test install command.'),
                [EvidenceRecord]::new('UninstallCommand', $uninstall, [EvidenceSource]::UserOverride,
                    [ConfidenceLevel]::High, 'Reviewed test uninstall command.')
            )
        }
        $outputPath = Join-Path $TestDrive 'malformed-version'

        $result = New-PackageScaffold -Path $script:ExeFixturePath -OutputPath $outputPath `
            -AdditionalEvidence (@($target, $version, $context) + $commands)
        $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json

        $result.Readiness | Should -Be 'NeedsInput'
        $result.DetectionPath | Should -BeNullOrEmpty
        @($manifest.Findings | Where-Object Code -eq 'DETECTION_LOW_CONFIDENCE').Count | Should -Be 1
        @($manifest.Findings | Where-Object Code -eq 'DETECTION_VERSION_UNCONFIRMED').Count | Should -Be 0
    }
}

<#
    Detection and manifest renderers. Generated detection scripts are executed in a fresh
    Windows PowerShell process so exit-code/STDOUT semantics are tested as ConfigMgr sees them.
#>

$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {

    Describe 'ConvertTo-DetectionScript' {

        It 'returns exit 0 with non-empty output when a file exists' {
            $target = Join-Path $TestDrive 'present.bin'
            Set-Content -LiteralPath $target -Value 'fixture'

            $rule = [DetectionSpec]::new()
            $rule.Kind       = [DetectionKind]::File
            $rule.Path       = $TestDrive
            $rule.FileName   = 'present.bin'
            $rule.Operator   = [DetectionOperator]::Exists
            $rule.Confidence = [ConfidenceLevel]::High

            $scriptPath = Join-Path $TestDrive 'detect-present.ps1'
            Set-Content -LiteralPath $scriptPath -Value (ConvertTo-DetectionScript $rule) -Encoding UTF8

            $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath)

            $LASTEXITCODE | Should -Be 0
            $output       | Should -Not -BeNullOrEmpty
        }

        It 'returns exit 0 with empty output when a file is absent' {
            $rule = [DetectionSpec]::new()
            $rule.Kind       = [DetectionKind]::File
            $rule.Path       = $TestDrive
            $rule.FileName   = 'absent.bin'
            $rule.Operator   = [DetectionOperator]::Exists
            $rule.Confidence = [ConfidenceLevel]::High

            $scriptPath = Join-Path $TestDrive 'detect-absent.ps1'
            Set-Content -LiteralPath $scriptPath -Value (ConvertTo-DetectionScript $rule) -Encoding UTF8
            $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath)

            $LASTEXITCODE | Should -Be 0
            $output       | Should -BeNullOrEmpty
        }

        It 'returns non-zero and STDERR when detection cannot evaluate a version' {
            $target = Join-Path $TestDrive 'unversioned.bin'
            Set-Content -LiteralPath $target -Value 'fixture'

            $rule = [DetectionSpec]::new()
            $rule.Kind       = [DetectionKind]::File
            $rule.Path       = $TestDrive
            $rule.FileName   = 'unversioned.bin'
            $rule.Operator   = [DetectionOperator]::GreaterOrEqual
            $rule.Value      = '1.0.0.0'
            $rule.Confidence = [ConfidenceLevel]::High

            $scriptPath = Join-Path $TestDrive 'detect-error.ps1'
            $errorPath  = Join-Path $TestDrive 'detect-error.txt'
            $outputPath = Join-Path $TestDrive 'detect-output.txt'
            Set-Content -LiteralPath $scriptPath -Value (ConvertTo-DetectionScript $rule) -Encoding UTF8
            $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $scriptPath)
            ) -Wait -PassThru -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath

            $process.ExitCode | Should -Not -Be 0
            (Get-Content -LiteralPath $outputPath -Raw) | Should -BeNullOrEmpty
            (Get-Content -LiteralPath $errorPath -Raw) | Should -BeLike '*Detection failed*'
        }

        It 'renders every detection kind as valid PowerShell under the 32 KB limit' {
            $file = [DetectionSpec]::new()
            $file.Kind = [DetectionKind]::File
            $file.Path = 'C:\Program Files\App'
            $file.FileName = 'app.exe'

            $registry = [DetectionSpec]::new()
            $registry.Kind = [DetectionKind]::Registry
            $registry.KeyPath = 'HKLM:\SOFTWARE\Vendor\App'
            $registry.ValueName = 'Version'
            $registry.RegistryView = [RegistryViewType]::Registry64

            $msi = [DetectionSpec]::new()
            $msi.Kind = [DetectionKind]::MsiProductCode
            $msi.Value = '{11111111-1111-1111-1111-111111111111}'

            foreach ($rule in @($file, $registry, $msi)) {
                $content = ConvertTo-DetectionScript $rule
                $tokens = $null
                $errors = $null
                $null = [System.Management.Automation.Language.Parser]::ParseInput(
                    $content, [ref] $tokens, [ref] $errors)

                $errors | Should -BeNullOrEmpty
                [Text.Encoding]::UTF8.GetByteCount($content) | Should -BeLessThan 32768
            }
        }
    }

    Describe 'Write-PackageManifest' {

        It 'writes a round-trippable authoritative manifest with raw and resolved evidence' {
            $fixture = Join-Path $ModuleRoot 'Tests\Fixtures\native-clean.msi'
            $context = [EvidenceRecord]::new(
                'SelectedContext', 'System', [EvidenceSource]::UserOverride, [ConfidenceLevel]::High)
            $info = Get-InstallerInfo -Path $fixture -AdditionalEvidence $context
            $spec = Resolve-PackageSpec -InstallerInfo $info
            $path = Join-Path $TestDrive 'PackageManifest.json'

            $file = Write-PackageManifest -InstallerInfo $info -PackageSpec $spec -OutputPath $path
            $manifest = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json

            $manifest.SchemaVersion                         | Should -Be $script:ManifestSchemaVersion
            $manifest.Installer.Evidence.Count              | Should -BeGreaterThan 0
            $manifest.Installer.ResolvedEvidence.Count      | Should -BeGreaterThan 0
            $manifest.Installer.Path                        | Should -Be 'native-clean.msi'
            $manifest.Installer.Path                        | Should -Not -Match '^[A-Z]:\\Users\\'
            $manifest.PackageSpec.InstallCommand.Executable | Should -Be 'msiexec.exe'
            $manifest.PackageSpec.DecisionEvidence.Count    | Should -Be 4
            $manifest.Readiness                             | Should -Be 'ReviewRequired'
        }
    }

    Describe 'New-PackageDocument' {

        BeforeAll {
            $fixture = Join-Path $ModuleRoot 'Tests\Fixtures\native-clean.msi'
            $context = [EvidenceRecord]::new(
                'SelectedContext', 'System', [EvidenceSource]::UserOverride, [ConfidenceLevel]::High)
            $script:Info = Get-InstallerInfo -Path $fixture -AdditionalEvidence $context
            $script:Spec = Resolve-PackageSpec -InstallerInfo $script:Info
        }

        It 'is a pure renderer: every value in the document traces back to the manifest' {
            $manifestPath = Join-Path $TestDrive 'PackageManifest.json'
            Write-PackageManifest -InstallerInfo $script:Info -PackageSpec $script:Spec -OutputPath $manifestPath

            $result = New-PackageDocument -ManifestPath $manifestPath
            $documentPath = Join-Path $TestDrive 'PackageDocument.md'

            $result.DocumentPath | Should -Be (Resolve-Path -LiteralPath $documentPath).ProviderPath
            $documentPath | Should -Exist

            $content = Get-Content -LiteralPath $documentPath -Raw
            $content | Should -Match 'Fixture Native'
            # The parentheses are required. In command-argument position PowerShell parses a
            # bare [type]::Method(...) as the literal string '[regex]::Escape', so without
            # them this asserted against nonsense and passed for the wrong reason.
            $content | Should -Match ([regex]::Escape('msiexec.exe /i native-clean.msi /qn'))
            $content | Should -Match ([regex]::Escape('msiexec.exe /x {B67274A8-A56D-4C2E-B1A0-7A59F5433BD2} /qn'))
            $content | Should -Match 'ReviewRequired'
        }

        It 'carries the verify-before-deploying checklist and the Win32_Product warning' {
            $manifestPath = Join-Path $TestDrive 'checklist\PackageManifest.json'
            Write-PackageManifest -InstallerInfo $script:Info -PackageSpec $script:Spec -OutputPath $manifestPath
            New-PackageDocument -ManifestPath $manifestPath | Out-Null

            $content = Get-Content -LiteralPath (Join-Path (Split-Path $manifestPath -Parent) 'PackageDocument.md') -Raw

            $content | Should -Match 'Verify before deploying'
            $content | Should -Match 'Win32_Product'
            $content | Should -Match 'forces'
            $content | Should -Match 'UpgradeCode'
            $content | Should -Match 'AppEnforce\.log'
            # Matched without the surrounding markdown emphasis, so rewording the bold in the
            # document does not break the assertion about its substance.
            $content | Should -Match 'treats a non-zero exit as Unknown'
            $content | Should -Match 'Intune evaluates a non-zero exit as "not installed"'
        }

        It 'warns that msiexec /x will not uninstall a wrapper MSI product' {
            $wrapperInfo = [InstallerInfo]::new()
            $wrapperInfo.FileName = 'wrapper.msi'
            $wrapperInfo.SHA256   = ('0' * 64)
            $wrapperInfo.FileSize = 1
            $wrapperInfo.ContainerType = [ContainerType]::Msi
            $wrapperInfo.MsiKind       = [MsiKind]::Wrapper
            $wrapperInfo.ProductCode   = '{11111111-1111-1111-1111-111111111111}'
            $wrapperInfo.Evidence         = @()
            $wrapperInfo.ResolvedEvidence = @()

            $wrapperSpec = [PackageSpec]::new()
            $wrapperSpec.InstallCommand   = [CommandSpec]::new('setup.exe', @('/S'))
            $wrapperSpec.UninstallCommand = [CommandSpec]::new('C:\Vendor\uninstall.exe', @('/S'))
            $wrapperSpec.SelectedContext  = [InstallContext]::System
            $wrapperSpec.DetectionSpec    = @([DetectionSpec]::new())
            $null = $wrapperSpec.RecalculateReadiness()

            $manifestPath = Join-Path $TestDrive 'wrapper\PackageManifest.json'
            Write-PackageManifest -InstallerInfo $wrapperInfo -PackageSpec $wrapperSpec -OutputPath $manifestPath
            New-PackageDocument -ManifestPath $manifestPath | Out-Null

            $content = Get-Content -LiteralPath (Join-Path (Split-Path $manifestPath -Parent) 'PackageDocument.md') -Raw
            $content | Should -Match 'Wrapper MSI'
            $content | Should -Match 'will \*\*not\*\* uninstall the product'
        }

        It 'does not write the document under -WhatIf' {
            $manifestPath = Join-Path $TestDrive 'whatif\PackageManifest.json'
            Write-PackageManifest -InstallerInfo $script:Info -PackageSpec $script:Spec -OutputPath $manifestPath

            New-PackageDocument -ManifestPath $manifestPath -WhatIf

            (Join-Path (Split-Path $manifestPath -Parent) 'PackageDocument.md') | Should -Not -Exist
        }

        It 'leaves no unresolved template token in the rendered document' {
            $manifestPath = Join-Path $TestDrive 'tokens\PackageManifest.json'
            Write-PackageManifest -InstallerInfo $script:Info -PackageSpec $script:Spec -OutputPath $manifestPath
            New-PackageDocument -ManifestPath $manifestPath | Out-Null

            $content = Get-Content -LiteralPath (Join-Path (Split-Path $manifestPath -Parent) 'PackageDocument.md') -Raw
            $content | Should -Not -Match '\{\{[A-Za-z0-9_]+\}\}'
        }
    }

    Describe 'Test-ScaffoldOutput' {

        BeforeAll {
            $fixture = Join-Path $ModuleRoot 'Tests\Fixtures\native-clean.msi'
            $context = [EvidenceRecord]::new(
                'SelectedContext', 'System', [EvidenceSource]::UserOverride, [ConfidenceLevel]::High)
            $script:Info = Get-InstallerInfo -Path $fixture -AdditionalEvidence $context
            $script:Spec = Resolve-PackageSpec -InstallerInfo $script:Info
        }

        It 'reports no findings against a healthy, self-consistent scaffold' {
            $outputPath = Join-Path $TestDrive 'healthy'
            [void] (New-Item -ItemType Directory -Path $outputPath -Force)

            $stagedInstaller = Join-Path $outputPath 'native-clean.msi'
            Copy-Item -LiteralPath $fixture -Destination $stagedInstaller

            $manifestPath = Join-Path $outputPath 'PackageManifest.json'
            Write-PackageManifest -InstallerInfo $script:Info -PackageSpec $script:Spec -OutputPath $manifestPath
            New-PackageDocument -ManifestPath $manifestPath | Out-Null
            New-DetectionMethod -DetectionSpec $script:Spec.DetectionSpec[0] -OutputPath $outputPath | Out-Null

            $findings = @(Test-ScaffoldOutput -OutputPath $outputPath -ManifestPath $manifestPath)
            $findings.Count | Should -Be 0
        }

        It 'flags an unresolved template token left in an emitted file' {
            $outputPath = Join-Path $TestDrive 'token'
            [void] (New-Item -ItemType Directory -Path $outputPath -Force)

            $stagedInstaller = Join-Path $outputPath 'native-clean.msi'
            Copy-Item -LiteralPath $fixture -Destination $stagedInstaller

            $manifestPath = Join-Path $outputPath 'PackageManifest.json'
            Write-PackageManifest -InstallerInfo $script:Info -PackageSpec $script:Spec -OutputPath $manifestPath
            Set-Content -LiteralPath (Join-Path $outputPath 'PackageDocument.md') -Value 'Left over {{TOKEN}}.'

            $findings = @(Test-ScaffoldOutput -OutputPath $outputPath -ManifestPath $manifestPath)
            $findings.Code | Should -Contain 'SCAFFOLD_UNRESOLVED_TOKEN'
            ($findings | Where-Object { $_.Code -eq 'SCAFFOLD_UNRESOLVED_TOKEN' }).Severity |
                Should -Be ([FindingSeverity]::Blocking)
        }

        It 'flags a generated .ps1 that does not parse' {
            $outputPath = Join-Path $TestDrive 'parse'
            [void] (New-Item -ItemType Directory -Path $outputPath -Force)

            $stagedInstaller = Join-Path $outputPath 'native-clean.msi'
            Copy-Item -LiteralPath $fixture -Destination $stagedInstaller

            $manifestPath = Join-Path $outputPath 'PackageManifest.json'
            Write-PackageManifest -InstallerInfo $script:Info -PackageSpec $script:Spec -OutputPath $manifestPath
            Set-Content -LiteralPath (Join-Path $outputPath 'Broken.ps1') -Value 'if ($true) {'

            $findings = @(Test-ScaffoldOutput -OutputPath $outputPath -ManifestPath $manifestPath)
            $findings.Code | Should -Contain 'SCAFFOLD_SCRIPT_PARSE_ERROR'
        }

        It 'flags a manifest that references a missing installer file' {
            $outputPath = Join-Path $TestDrive 'missing'
            [void] (New-Item -ItemType Directory -Path $outputPath -Force)

            $manifestPath = Join-Path $outputPath 'PackageManifest.json'
            Write-PackageManifest -InstallerInfo $script:Info -PackageSpec $script:Spec -OutputPath $manifestPath

            $findings = @(Test-ScaffoldOutput -OutputPath $outputPath -ManifestPath $manifestPath)
            $findings.Code | Should -Contain 'SCAFFOLD_MISSING_REFERENCED_FILE'
        }

        It 'flags a staged installer whose hash no longer matches the manifest' {
            $outputPath = Join-Path $TestDrive 'hash'
            [void] (New-Item -ItemType Directory -Path $outputPath -Force)

            $manifestPath = Join-Path $outputPath 'PackageManifest.json'
            Write-PackageManifest -InstallerInfo $script:Info -PackageSpec $script:Spec -OutputPath $manifestPath
            Set-Content -LiteralPath (Join-Path $outputPath 'native-clean.msi') -Value 'tampered'

            $findings = @(Test-ScaffoldOutput -OutputPath $outputPath -ManifestPath $manifestPath)
            $findings.Code | Should -Contain 'SCAFFOLD_HASH_MISMATCH'
        }

        It 'flags a detection script at or over the ConfigMgr 32 KB limit' {
            $outputPath = Join-Path $TestDrive 'oversized'
            [void] (New-Item -ItemType Directory -Path $outputPath -Force)

            $stagedInstaller = Join-Path $outputPath 'native-clean.msi'
            Copy-Item -LiteralPath $fixture -Destination $stagedInstaller

            $manifestPath = Join-Path $outputPath 'PackageManifest.json'
            Write-PackageManifest -InstallerInfo $script:Info -PackageSpec $script:Spec -OutputPath $manifestPath
            Set-Content -LiteralPath (Join-Path $outputPath 'Detect-Application.ps1') -Value ('#' + ('x' * 33000))

            $findings = @(Test-ScaffoldOutput -OutputPath $outputPath -ManifestPath $manifestPath)
            $findings.Code | Should -Contain 'SCAFFOLD_DETECTION_SCRIPT_TOO_LARGE'
        }
    }
}

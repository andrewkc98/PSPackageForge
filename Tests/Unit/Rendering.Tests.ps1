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
}

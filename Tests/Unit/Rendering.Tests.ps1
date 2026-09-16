<#
    Detection and manifest renderers. Generated detection scripts are executed in a fresh
    Windows PowerShell process so exit-code/STDOUT semantics are tested as ConfigMgr sees them.
#>

$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {

    Describe 'Markdown document value helpers' {

        It 'renders a complete code span without escaping paths, braces, pipes, or backticks' {
            $value = ' C:\Program Files\A{b}|x``' + [Environment]::NewLine + ' '
            $result = ConvertTo-DocumentCodeSpan $value

            $result.Substring(0, 3) | Should -Be '```'
            $result.Substring($result.Length - 3) | Should -Be '```'
            $result.Substring(3, $result.Length - 6) | Should -Be '  C:\Program Files\A{b}|x``   '
        }

        It 'uses a delimiter longer than the longest internal backtick run' {
            $result = ConvertTo-DocumentCodeSpan 'left````right'

            $result | Should -Be '`````left````right`````'
        }

        It 'separates delimiters from boundary backticks and preserves whitespace-only values' {
            ConvertTo-DocumentCodeSpan '`edge`' | Should -Be '`` `edge` ``'
            ConvertTo-DocumentCodeSpan '   ' | Should -Be '`   `'
        }

        It 'keeps ordinary prose escaping separate from code-span rendering' {
            ConvertTo-DocumentText 'C:\A{b}|x' | Should -Be 'C:\\A\{b\}\|x'
            ConvertTo-DocumentCodeSpan 'C:\A{b}|x' | Should -Be '`C:\A{b}|x`'
            ConvertTo-DocumentCodeSpan 'C:\A{b}|x' -ForTable | Should -Be '`C:\A{b}\|x`'
        }

        It 'renders unresolved and low-confidence application architecture as Unknown' {
            Get-DocumentApplicationArchitecture ([pscustomobject]@{
                ApplicationArchitecture = 'x64'
                ResolvedEvidence = @([pscustomobject]@{
                    Field = 'ApplicationArchitecture'
                    Confidence = 'Low'
                })
            }) | Should -Be 'Unknown'

            Get-DocumentApplicationArchitecture ([pscustomobject]@{}) | Should -Be 'Unknown'
        }

        It 'renders high-confidence schema-2 application architecture' {
            Get-DocumentApplicationArchitecture ([pscustomobject]@{
                ApplicationArchitecture = 'x64'
                ResolvedEvidence = @([pscustomobject]@{
                    Field = 'ApplicationArchitecture'
                    Confidence = 'High'
                })
            }) | Should -Be 'x64'
        }

        It 'renders complete template code spans without adding a second wrapper' {
            $manifest = [pscustomobject]@{
                Generator = [pscustomobject]@{ Version = '1.0' }
                SchemaVersion = 2
                GeneratedAtUtc = '2026-01-01T00:00:00Z'
                Readiness = 'ReviewRequired'
                Installer = [pscustomobject]@{
                    ProductName = 'Demo'
                    FileName = 'C:\Path\`tool`|x'
                    SHA256 = 'abc'
                    FileSize = 3
                    Signature = [pscustomobject]@{ IsSigned = $false; Status = 'Unsigned'; SignerSubject = $null }
                    ContainerType = 'Exe'
                    PayloadType = 'Exe'
                    MsiKind = 'NotMsi'
                    ApplicationArchitecture = 'x64'
                    Manufacturer = 'Vendor'
                    ProductVersionRaw = '1.0'
                    ProductCode = '{ABC}'
                    UpgradeCode = '{XYZ}'
                    Evidence = @()
                    ResolvedEvidence = @()
                }
                PackageSpec = [pscustomobject]@{
                    InstallCommand = $null
                    UninstallCommand = $null
                    DetectionSpec = @()
                    SelectedContext = 'System'
                    RequiresLogonWhenUserContext = $false
                    ReturnCodeMap = @()
                }
                Findings = @()
            }

            $content = ConvertTo-PackageDocumentContent -Manifest $manifest
            $content | Should -Match ([regex]::Escape('| Filename | ``C:\Path\`tool`\|x`` |'))
            $content | Should -Match ([regex]::Escape('| Product code | `{ABC}` |'))
            $content | Should -Not -Match ([regex]::Escape('| Filename | ```'))
        }
    }

    Describe 'ConvertTo-DetectionScript' {

        BeforeAll {
            $script:DetectionShell = if ($PSVersionTable.PSEdition -eq 'Desktop') {
                Get-Command powershell.exe -ErrorAction SilentlyContinue
            }
            else {
                Get-Command pwsh -ErrorAction SilentlyContinue
            }
        }

        It 'returns exit 0 with non-empty output when a file exists' `
            -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {
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

        It 'returns exit 0 with empty output when a file is absent' `
            -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {
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

        It 'returns non-zero and STDERR when detection cannot evaluate a version' `
            -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {
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

        It 'builds the File/Exact and File/GreaterOrEqual actual version from the binary FileXPart properties, not the FileVersion string (H1)' {
            $rule = [DetectionSpec]::new()
            $rule.Kind     = [DetectionKind]::File
            $rule.Path     = 'C:\Program Files\App'
            $rule.FileName = 'app.exe'
            $rule.Operator = [DetectionOperator]::Exact
            $rule.Value    = '1.2.3.4'

            $content = ConvertTo-DetectionScript $rule

            $content | Should -Match 'FileMajorPart'
            $content | Should -Match 'FileMinorPart'
            $content | Should -Match 'FileBuildPart'
            $content | Should -Match 'FilePrivatePart'
            # The bug this fixes was comparing the arbitrary FileVersion string resource
            # directly; that comparison must be gone from the generated script entirely.
            $content | Should -Not -Match 'VersionInfo\.FileVersion\s*-eq'
        }

        It 'renders wildcard file rules as deterministic any-match probes with terminating errors' {
            $rule = [DetectionSpec]::new()
            $rule.Kind = [DetectionKind]::File
            $rule.Path = 'C:\Program Files\App'
            $rule.FileName = '*.bin'
            $rule.Operator = [DetectionOperator]::Exists
            $rule.UsesWildcardPath = $true

            $content = ConvertTo-DetectionScript $rule

            $content | Should -Match 'Get-ChildItem -Path \$target -File -ErrorAction Stop'
            $content | Should -Match 'foreach \(\$candidate in \$candidates\)'
            $content | Should -Not -Match 'Select-Object -First 1'
            $content | Should -Match "CategoryInfo\.Category -eq 'ObjectNotFound'"
            $content | Should -Match '# A metadata failure is definitive'
        }

        It 'executes a wildcard Exists rule against every matching candidate on portable PowerShell' {
            $shell = $script:DetectionShell
            if ($null -eq $shell) {
                Set-ItResult -Skipped -Because 'No supported PowerShell executable is available.'
                return
            }

            $target = Join-Path $TestDrive 'side-by-side'
            New-Item -ItemType Directory -Path $target | Out-Null
            Set-Content -LiteralPath (Join-Path $target 'a-8.bin') -Value 'old'
            Set-Content -LiteralPath (Join-Path $target 'z-9.bin') -Value 'new'

            $rule = [DetectionSpec]::new()
            $rule.Kind = [DetectionKind]::File
            $rule.Path = $target
            $rule.FileName = '*.bin'
            $rule.Operator = [DetectionOperator]::Exists
            $rule.UsesWildcardPath = $true
            $scriptPath = Join-Path $TestDrive 'detect-wildcard.ps1'
            Set-Content -LiteralPath $scriptPath -Value (ConvertTo-DetectionScript $rule) -Encoding UTF8

            $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $scriptPath)
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'a-8\.bin|z-9\.bin'
        }

        It 'matches the later alphabetic candidate by binary version for Exact rules' {
            $shell = $script:DetectionShell
            if ($null -eq $shell) {
                Set-ItResult -Skipped -Because 'No supported PowerShell executable is available.'
                return
            }

            $target = Join-Path $TestDrive 'exact-versions'
            New-Item -ItemType Directory -Path $target | Out-Null
            Add-Type -TypeDefinition 'using System.Reflection; [assembly: AssemblyFileVersion("8.0.0.0")] public class ExactVersionEight {}' -OutputAssembly (Join-Path $target 'a-8.dll') -OutputType Library
            Add-Type -TypeDefinition 'using System.Reflection; [assembly: AssemblyFileVersion("9.0.0.0")] public class ExactVersionNine {}' -OutputAssembly (Join-Path $target 'z-9.dll') -OutputType Library

            $rule = [DetectionSpec]::new()
            $rule.Kind = [DetectionKind]::File
            $rule.Path = $target
            $rule.FileName = '*.dll'
            $rule.Operator = [DetectionOperator]::Exact
            $rule.Value = '9.0.0.0'
            $rule.UsesWildcardPath = $true
            $scriptPath = Join-Path $TestDrive 'detect-exact-any-match.ps1'
            Set-Content -LiteralPath $scriptPath -Value (ConvertTo-DetectionScript $rule) -Encoding UTF8

            $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $scriptPath)
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'z-9\.dll'
        }

        It 'matches the later alphabetic candidate by binary version for GreaterOrEqual rules' {
            $shell = $script:DetectionShell
            if ($null -eq $shell) {
                Set-ItResult -Skipped -Because 'No supported PowerShell executable is available.'
                return
            }

            $target = Join-Path $TestDrive 'ge-versions'
            New-Item -ItemType Directory -Path $target | Out-Null
            Add-Type -TypeDefinition 'using System.Reflection; [assembly: AssemblyFileVersion("8.0.0.0")] public class GreaterVersionEight {}' -OutputAssembly (Join-Path $target 'a-8.dll') -OutputType Library
            Add-Type -TypeDefinition 'using System.Reflection; [assembly: AssemblyFileVersion("9.0.0.0")] public class GreaterVersionNine {}' -OutputAssembly (Join-Path $target 'z-9.dll') -OutputType Library

            $rule = [DetectionSpec]::new()
            $rule.Kind = [DetectionKind]::File
            $rule.Path = $target
            $rule.FileName = '*.dll'
            $rule.Operator = [DetectionOperator]::GreaterOrEqual
            $rule.Value = '8.5.0.0'
            $rule.UsesWildcardPath = $true
            $scriptPath = Join-Path $TestDrive 'detect-ge-any-match.ps1'
            Set-Content -LiteralPath $scriptPath -Value (ConvertTo-DetectionScript $rule) -Encoding UTF8

            $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $scriptPath)
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'z-9\.dll'
        }

        It 'fails immediately on a bad alphabetic candidate before a later matching candidate' {
            $shell = $script:DetectionShell
            if ($null -eq $shell) {
                Set-ItResult -Skipped -Because 'No supported PowerShell executable is available.'
                return
            }

            $target = Join-Path $TestDrive 'bad-first'
            New-Item -ItemType Directory -Path $target | Out-Null
            Set-Content -LiteralPath (Join-Path $target 'a-bad.dll') -Value 'not a binary'
            Add-Type -TypeDefinition 'using System.Reflection; [assembly: AssemblyFileVersion("9.0.0.0")] public class GoodAfterBad {}' -OutputAssembly (Join-Path $target 'z-good.dll') -OutputType Library

            $rule = [DetectionSpec]::new()
            $rule.Kind = [DetectionKind]::File
            $rule.Path = $target
            $rule.FileName = '*.dll'
            $rule.Operator = [DetectionOperator]::Exact
            $rule.Value = '9.0.0.0'
            $rule.UsesWildcardPath = $true
            $scriptPath = Join-Path $TestDrive 'detect-bad-first.ps1'
            Set-Content -LiteralPath $scriptPath -Value (ConvertTo-DetectionScript $rule) -Encoding UTF8

            $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2>&1)
            $LASTEXITCODE | Should -Be 2
            $output | Should -Match 'Detection failed'
        }

        It 'returns after a satisfying candidate before a later versionless candidate' {
            $shell = $script:DetectionShell
            if ($null -eq $shell) {
                Set-ItResult -Skipped -Because 'No supported PowerShell executable is available.'
                return
            }

            $target = Join-Path $TestDrive 'good-first'
            New-Item -ItemType Directory -Path $target | Out-Null
            Add-Type -TypeDefinition 'using System.Reflection; [assembly: AssemblyFileVersion("9.0.0.0")] public class GoodBeforeBad {}' -OutputAssembly (Join-Path $target 'a-good.dll') -OutputType Library
            Set-Content -LiteralPath (Join-Path $target 'z-bad.dll') -Value 'not a binary'

            $rule = [DetectionSpec]::new()
            $rule.Kind = [DetectionKind]::File
            $rule.Path = $target
            $rule.FileName = '*.dll'
            $rule.Operator = [DetectionOperator]::Exact
            $rule.Value = '9.0.0.0'
            $rule.UsesWildcardPath = $true
            $scriptPath = Join-Path $TestDrive 'detect-good-first.ps1'
            Set-Content -LiteralPath $scriptPath -Value (ConvertTo-DetectionScript $rule) -Encoding UTF8

            $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $scriptPath)
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'a-good\.dll'
        }

        It 'returns exit 2 and stderr for a terminating access probe failure' {
            $shell = $script:DetectionShell
            if ($null -eq $shell) {
                Set-ItResult -Skipped -Because 'No supported PowerShell executable is available.'
                return
            }

            $rule = [DetectionSpec]::new()
            $rule.Kind = [DetectionKind]::File
            $rule.Path = $TestDrive
            $rule.FileName = '*.bin'
            $rule.Operator = [DetectionOperator]::Exists
            $rule.UsesWildcardPath = $true
            $scriptPath = Join-Path $TestDrive 'detect-access-shim.ps1'
            $errorPath = Join-Path $TestDrive 'detect-access-shim.err'
            $shim = @'
function Get-ChildItem { throw [System.UnauthorizedAccessException]::new("access denied") }
'@
            Set-Content -LiteralPath $scriptPath -Value ($shim + [Environment]::NewLine + (ConvertTo-DetectionScript $rule)) -Encoding UTF8

            $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2> $errorPath)
            $LASTEXITCODE | Should -Be 2
            $output | Should -BeNullOrEmpty
            (Get-Content -LiteralPath $errorPath -Raw) | Should -Match 'Detection failed'
        }

        It 'returns exit 0 and empty output for a wildcard with zero matches on portable PowerShell' {
            $shell = $script:DetectionShell
            if ($null -eq $shell) {
                Set-ItResult -Skipped -Because 'No supported PowerShell executable is available.'
                return
            }

            $rule = [DetectionSpec]::new()
            $rule.Kind = [DetectionKind]::File
            $rule.Path = $TestDrive
            $rule.FileName = 'no-such-*.bin'
            $rule.Operator = [DetectionOperator]::Exists
            $rule.UsesWildcardPath = $true
            $scriptPath = Join-Path $TestDrive 'detect-no-wildcard-match.ps1'
            Set-Content -LiteralPath $scriptPath -Value (ConvertTo-DetectionScript $rule) -Encoding UTF8

            $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $scriptPath)
            $LASTEXITCODE | Should -Be 0
            $output | Should -BeNullOrEmpty
        }

        It 'returns exit 2 with stderr for a versionless candidate on portable PowerShell' {
            $shell = $script:DetectionShell
            if ($null -eq $shell) {
                Set-ItResult -Skipped -Because 'No supported PowerShell executable is available.'
                return
            }

            $target = Join-Path $TestDrive 'versionless.bin'
            Set-Content -LiteralPath $target -Value 'fixture'
            $rule = [DetectionSpec]::new()
            $rule.Kind = [DetectionKind]::File
            $rule.Path = $TestDrive
            $rule.FileName = 'versionless.bin'
            $rule.Operator = [DetectionOperator]::GreaterOrEqual
            $rule.Value = '1.0.0.0'
            $scriptPath = Join-Path $TestDrive 'detect-versionless-portable.ps1'
            $errorPath = Join-Path $TestDrive 'detect-versionless-portable.err'
            Set-Content -LiteralPath $scriptPath -Value (ConvertTo-DetectionScript $rule) -Encoding UTF8

            $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $scriptPath 2> $errorPath)
            $LASTEXITCODE | Should -Be 2
            $output | Should -BeNullOrEmpty
            (Get-Content -LiteralPath $errorPath -Raw) | Should -Match 'Detection failed'
        }

        It 'detects an Exact file-version rule from the binary version even when the FileVersion string resource differs (H1 regression)' `
            -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {
            $target = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $target)) {
                Set-ItResult -Skipped -Because 'powershell.exe was not found at the expected System32 path.'
                return
            }

            $vi = (Get-Item -LiteralPath $target).VersionInfo
            $binaryVersion = [version]::new($vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart)

            $rule = [DetectionSpec]::new()
            $rule.Kind       = [DetectionKind]::File
            $rule.Path       = Split-Path -Path $target -Parent
            $rule.FileName   = Split-Path -Path $target -Leaf
            $rule.Operator   = [DetectionOperator]::Exact
            $rule.Value      = $binaryVersion.ToString()
            $rule.Confidence = [ConfidenceLevel]::High

            $scriptPath = Join-Path $TestDrive 'detect-exact-binary-version.ps1'
            Set-Content -LiteralPath $scriptPath -Value (ConvertTo-DetectionScript $rule) -Encoding UTF8
            $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath)

            $LASTEXITCODE | Should -Be 0
            $output       | Should -Not -BeNullOrEmpty
        }

        It 'detects a GreaterOrEqual file-version rule using zero-padded version comparison' `
            -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {
            $target = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $target)) {
                Set-ItResult -Skipped -Because 'powershell.exe was not found at the expected System32 path.'
                return
            }

            $vi = (Get-Item -LiteralPath $target).VersionInfo
            # A 3-part required value (no Revision) exercises the -1 -> 0 padding directly.
            $lowerVersion = [version]::new($vi.FileMajorPart, $vi.FileMinorPart, 0)

            $rule = [DetectionSpec]::new()
            $rule.Kind       = [DetectionKind]::File
            $rule.Path       = Split-Path -Path $target -Parent
            $rule.FileName   = Split-Path -Path $target -Leaf
            $rule.Operator   = [DetectionOperator]::GreaterOrEqual
            $rule.Value      = $lowerVersion.ToString()
            $rule.Confidence = [ConfidenceLevel]::High

            $scriptPath = Join-Path $TestDrive 'detect-ge-binary-version.ps1'
            Set-Content -LiteralPath $scriptPath -Value (ConvertTo-DetectionScript $rule) -Encoding UTF8
            $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath)

            $LASTEXITCODE | Should -Be 0
            $output       | Should -Not -BeNullOrEmpty
        }
    }

    Describe 'Resolve-DetectionSpec' {

        It 'demotes an unparseable DetectionTargetVersion to Exists with Low confidence (M4)' {
            $info = [InstallerInfo]::new()
            $info.ResolvedEvidence = @(
                [EvidenceRecord]::new('DetectionTarget', 'C:\Program Files\App\app.exe', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High),
                [EvidenceRecord]::new('DetectionTargetVersion', '26.02 beta', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
            )

            $rule = Resolve-DetectionSpec -InstallerInfo $info

            $rule.Kind       | Should -Be ([DetectionKind]::File)
            $rule.Operator   | Should -Be ([DetectionOperator]::Exists)
            $rule.Confidence | Should -Be ([ConfidenceLevel]::Low)
            $rule.Value      | Should -BeNullOrEmpty
            $rule.Rationale  | Should -Match ([regex]::Escape('26.02 beta'))
            $rule.Rationale  | Should -Match 'could not be parsed'
        }

        It 'keeps version-comparison behavior for a parseable DetectionTargetVersion' {
            $info = [InstallerInfo]::new()
            $info.ResolvedEvidence = @(
                [EvidenceRecord]::new('DetectionTarget', 'C:\Program Files\App\app.exe', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High),
                [EvidenceRecord]::new('DetectionTargetVersion', '1.2.3.4', [EvidenceSource]::MsiDatabase, [ConfidenceLevel]::High)
            )

            $rule = Resolve-DetectionSpec -InstallerInfo $info

            $rule.Operator   | Should -Be ([DetectionOperator]::Exact)
            $rule.Value      | Should -Be '1.2.3.4'
            $rule.Confidence | Should -Be ([ConfidenceLevel]::High)
        }
    }

    Describe 'Write-PackageManifest' `
        -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {

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

    Describe 'New-PackageDocument' `
        -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {

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

        It 'escapes Markdown/HTML-active characters from installer-derived text before it reaches the document (M3)' {
            $maliciousInfo = [InstallerInfo]::new()
            $maliciousInfo.FileName      = 'setup.exe'
            $maliciousInfo.SHA256        = ('0' * 64)
            $maliciousInfo.FileSize      = 1
            $maliciousInfo.ContainerType = [ContainerType]::Exe
            $maliciousInfo.ProductName   = '# Findings: none | {{SHA256}} `code` <script>'
            $maliciousInfo.Evidence         = @()
            $maliciousInfo.ResolvedEvidence = @()

            $maliciousSpec = [PackageSpec]::new()
            $maliciousSpec.InstallCommand   = [CommandSpec]::new('setup.exe', @('/S'))
            $maliciousSpec.UninstallCommand = [CommandSpec]::new('setup.exe', @('/S', '/uninstall'))
            $maliciousSpec.SelectedContext  = [InstallContext]::System
            $maliciousSpec.DetectionSpec    = @([DetectionSpec]::new())
            $null = $maliciousSpec.RecalculateReadiness()

            $manifestPath = Join-Path $TestDrive 'malicious\PackageManifest.json'
            Write-PackageManifest -InstallerInfo $maliciousInfo -PackageSpec $maliciousSpec -OutputPath $manifestPath
            New-PackageDocument -ManifestPath $manifestPath | Out-Null

            $content = Get-Content -LiteralPath (Join-Path (Split-Path $manifestPath -Parent) 'PackageDocument.md') -Raw

            # Every Markdown/HTML-active character escaped, in order, with a preceding backslash.
            $content | Should -Match ([regex]::Escape('\# Findings: none \| \{\{SHA256\}\} \`code\` \<script\>'))
            $content | Should -Not -Match '<script>'
            $content | Should -Not -Match '\{\{SHA256\}\}'
        }

        It 'throws naming the token when the template references one the renderer does not provide' {
            $originalTemplateRoot = $script:TemplateRoot
            try {
                $badTemplateRoot = Join-Path $TestDrive 'bad-template'
                [void] (New-Item -ItemType Directory -Path $badTemplateRoot -Force)
                Set-Content -LiteralPath (Join-Path $badTemplateRoot 'PackageDocument.md.template') -Value 'Hello {{NOT_A_REAL_TOKEN}}'
                $script:TemplateRoot = $badTemplateRoot

                $manifestPath = Join-Path $TestDrive 'badtemplate\PackageManifest.json'
                Write-PackageManifest -InstallerInfo $script:Info -PackageSpec $script:Spec -OutputPath $manifestPath
                $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

                { ConvertTo-PackageDocumentContent -Manifest $manifest } | Should -Throw '*NOT_A_REAL_TOKEN*'
            }
            finally {
                $script:TemplateRoot = $originalTemplateRoot
            }
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

    Describe 'Test-ScaffoldOutput' `
        -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {

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
            # Must be a real PackageDocument.md.template token name -- the check now only
            # flags {{TOKEN}} occurrences that match the template's own declared tokens.
            Set-Content -LiteralPath (Join-Path $outputPath 'PackageDocument.md') -Value 'Left over {{PRODUCT_NAME}}.'

            $findings = @(Test-ScaffoldOutput -OutputPath $outputPath -ManifestPath $manifestPath)
            $findings.Code | Should -Contain 'SCAFFOLD_UNRESOLVED_TOKEN'
            ($findings | Where-Object { $_.Code -eq 'SCAFFOLD_UNRESOLVED_TOKEN' }).Severity |
                Should -Be ([FindingSeverity]::Blocking)
        }

        It 'does not flag {{...}}-shaped text whose name is not a real PackageDocument.md.template token' {
            $outputPath = Join-Path $TestDrive 'fake-token'
            [void] (New-Item -ItemType Directory -Path $outputPath -Force)

            $stagedInstaller = Join-Path $outputPath 'native-clean.msi'
            Copy-Item -LiteralPath $fixture -Destination $stagedInstaller

            $manifestPath = Join-Path $outputPath 'PackageManifest.json'
            Write-PackageManifest -InstallerInfo $script:Info -PackageSpec $script:Spec -OutputPath $manifestPath
            # {{NOT_A_REAL_TOKEN}} is not a name the template declares, so this is
            # indistinguishable from reviewed content and must not be flagged.
            Set-Content -LiteralPath (Join-Path $outputPath 'PackageDocument.md') -Value 'See {{NOT_A_REAL_TOKEN}} above.'

            # Reading .Code off a possibly-empty typed array throws under Set-StrictMode
            # -Version Latest, so assert on .Count instead: this scaffold is otherwise
            # self-consistent, so the safe assertion is simply zero findings.
            $findings = @(Test-ScaffoldOutput -OutputPath $outputPath -ManifestPath $manifestPath)
            $findings.Count | Should -Be 0
        }

        It 'does not flag the rendered document when installer-derived text literally contains escaped token syntax (L1)' {
            $outputPath = Join-Path $TestDrive 'tricky-token'
            [void] (New-Item -ItemType Directory -Path $outputPath -Force)

            $stagedInstaller = Join-Path $outputPath 'setup.exe'
            Set-Content -LiteralPath $stagedInstaller -Value 'fixture' -Encoding Ascii
            $stagedHash = (Get-FileHash -LiteralPath $stagedInstaller -Algorithm SHA256).Hash

            $trickyInfo = [InstallerInfo]::new()
            $trickyInfo.FileName      = 'setup.exe'
            $trickyInfo.SHA256        = $stagedHash
            $trickyInfo.FileSize      = (Get-Item -LiteralPath $stagedInstaller).Length
            $trickyInfo.ContainerType = [ContainerType]::Exe
            # Contains literal token syntax for a *different* real token (SHA256). The old
            # iterative substitution would have let this get rewritten into the actual hash
            # when the SHA256 key was processed; the new single-pass substitution must not.
            $trickyInfo.ProductName   = 'Contains {{SHA256}} literally'
            $trickyInfo.Evidence         = @()
            $trickyInfo.ResolvedEvidence = @()

            $trickySpec = [PackageSpec]::new()
            $trickySpec.InstallCommand   = [CommandSpec]::new('setup.exe', @('/S'))
            $trickySpec.UninstallCommand = [CommandSpec]::new('setup.exe', @('/S', '/uninstall'))
            $trickySpec.SelectedContext  = [InstallContext]::System
            $trickySpec.DetectionSpec    = @([DetectionSpec]::new())
            $null = $trickySpec.RecalculateReadiness()

            $manifestPath = Join-Path $outputPath 'PackageManifest.json'
            Write-PackageManifest -InstallerInfo $trickyInfo -PackageSpec $trickySpec -OutputPath $manifestPath
            New-PackageDocument -ManifestPath $manifestPath | Out-Null

            $content = Get-Content -LiteralPath (Join-Path $outputPath 'PackageDocument.md') -Raw
            $content | Should -Match ([regex]::Escape('Contains \{\{SHA256\}\} literally'))
            $content | Should -Not -Match ('Contains ' + [regex]::Escape($stagedHash) + ' literally')

            # PackageManifest.json is raw, unescaped installer data (not a rendered document),
            # so it legitimately still contains the literal '{{SHA256}}' text and is expected
            # to be flagged -- that is orthogonal to this fix. What L1 guarantees is that the
            # *rendered* PackageDocument.md, which the escaping and single-pass substitution
            # actually govern, is never flagged.
            $findings = @(Test-ScaffoldOutput -OutputPath $outputPath -ManifestPath $manifestPath)
            $documentTokenFindings = @($findings | Where-Object {
                $_.Code -eq 'SCAFFOLD_UNRESOLVED_TOKEN' -and $_.Message -like '*PackageDocument.md*'
            })
            $documentTokenFindings.Count | Should -Be 0
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

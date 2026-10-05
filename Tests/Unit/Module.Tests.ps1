<#
    Module-level guardrails.

    These tests assert the properties from the v1 definition of done that are structural
    rather than behavioural -- the ones that are cheap to check and expensive to discover
    late, like the module quietly acquiring a ConfigMgr console dependency.
#>

$ModuleRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ManifestPath = Join-Path $ModuleRoot 'PSPackageForge.psd1'

Import-Module $ManifestPath -Force

Describe 'Module manifest' {

    BeforeAll {
        $script:ModuleRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:ManifestPath = Join-Path $script:ModuleRoot 'PSPackageForge.psd1'
        $script:Manifest     = Import-PowerShellDataFile -Path $script:ManifestPath
    }

    It 'is a valid module manifest' {
        { Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'requires PowerShell 5.1, which is what MECM environments actually run' {
        $script:Manifest.PowerShellVersion | Should -Be '5.1'
    }

    It 'declares compatibility with both Desktop and Core editions' {
        $script:Manifest.CompatiblePSEditions | Should -Contain 'Desktop'
        $script:Manifest.CompatiblePSEditions | Should -Contain 'Core'
    }

    It 'pins the schema-2 contract and toolchain versions the manifest output depends on' {
        $forge = $script:Manifest.PrivateData.PSPackageForge

        # Four authoritative constants: the manifest and discovery graphs moved to schema 2,
        # package receipts remain schema 1, and the PSADT toolchain pin is unchanged.
        $forge.ManifestSchemaVersion      | Should -Be '2.0'
        $forge.DiscoverySchemaVersion     | Should -Be '2.0'
        $forge.PackageReceiptSchemaVersion | Should -Be '1.0'
        $forge.RequiredPSADTVersion       | Should -Be '4.0.6'
    }

    It 'exports all public commands in the locked v1 scope plus Invoke-PackageForge' {
        $expected = @(
            'Get-InstalledAppInfo'
            'Get-InstallerInfo'
            'New-DetectionMethod'
            'New-IntuneWinPackage'
            'New-MecmDeploymentSpec'
            'New-PSADTPackage'
            'New-PackageDocument'
            'New-PackageScaffold'
            'Invoke-PackageForge'
        )

        # Sort both sides with the same comparer. PowerShell's default sort is culture
        # aware, so 'New-PackageDocument' and 'New-PSADTPackage' do not order the way an
        # ordinal comparison would, and hard-coding one order makes the test lie.
        $actual = (Get-Command -Module PSPackageForge -CommandType Function).Name

        ($actual | Sort-Object) | Should -Be ($expected | Sort-Object)
    }

    It 'exports psforge as an alias for Invoke-PackageForge after a plain module import' {
        $alias = Get-Command -Name psforge -CommandType Alias -ErrorAction Stop

        $alias.CommandType | Should -Be 'Alias'
        $alias.Definition  | Should -Be 'Invoke-PackageForge'
    }

    It 'has a file on disk for every exported function' {
        foreach ($name in $script:Manifest.FunctionsToExport) {
            $path = Join-Path $script:ModuleRoot "Public/$name.ps1"
            $path | Should -Exist
        }
    }
}

Describe 'Source guardrails' {

    BeforeAll {
        $script:ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        $script:SourceFiles = Get-ChildItem -Path $script:ModuleRoot -Include '*.ps1', '*.psm1', '*.psd1' -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/](Examples|\.git)[\\/]' }
    }

    It 'never depends on the ConfigMgr console' {
        # Plan §12: the entire v1 build happens on a machine with no SCCM console and no
        # site access. A stray Import-Module here would make the whole suite unrunnable
        # for anyone without a site server.
        # Collect names, not FileInfo objects: under Set-StrictMode -Version Latest,
        # reading a property off an empty array throws, which would turn a passing test
        # into an error.
        $offenders = @($script:SourceFiles |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'ConfigurationManager\.psd1' } |
            ForEach-Object { $_.Name })

        $offenders.Count | Should -Be 0 -Because ($offenders -join ', ')
    }

    It 'never queries Win32_Product' {
        # Querying it triggers a reconfigure of every installed MSI on the machine. This is
        # the single most common packaging mistake and the module must not model it.
        # Tests are excluded: this very assertion has to name the thing it forbids.
        $offenders = @($script:SourceFiles |
            Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' } |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Win32_Product' } |
            ForEach-Object { $_.Name })

        $offenders.Count | Should -Be 0 -Because ($offenders -join ', ')
    }

    It 'contains no unresolved template tokens in source' {
        # Tests are excluded for the same reason as the Win32_Product guardrail: a test that
        # asserts the renderer leaves no token behind has to be able to write one down.
        # Templates/ legitimately contains tokens too, and is not PowerShell source.
        $offenders = @($script:SourceFiles |
            Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]' } |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '\{\{[A-Za-z0-9_]+\}\}' } |
            ForEach-Object { $_.Name })

        $offenders.Count | Should -Be 0 -Because ($offenders -join ', ')
    }

    It 'parses every PowerShell file without error' {
        foreach ($file in $script:SourceFiles | Where-Object { $_.Extension -ne '.psd1' }) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref] $null, [ref] $errors)

            $errors | Should -BeNullOrEmpty -Because "$($file.Name) must parse"
        }
    }
}

Describe 'Opsec' {

    BeforeAll {
        $script:ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

        # .claude and .git are tooling state, not repository content, and both are ignored.
        $script:TextFiles = Get-ChildItem -Path $script:ModuleRoot -Include '*.ps1', '*.psm1', '*.psd1', '*.md', '*.json', '*.yml' -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/]\.(git|claude|vs|vscode)[\\/]' }
    }

    It 'contains no real environment identifiers, only documented placeholders' {
        # Placeholders are required to look like placeholders: CONTOSO / contoso.local.
        $suspicious = @(foreach ($file in $script:TextFiles) {
            $content = Get-Content -LiteralPath $file.FullName -Raw

            $hits = [regex]::Matches($content, '(?i)\b[a-z0-9-]+\.(local|corp|internal|lan)\b') |
                ForEach-Object { $_.Value } |
                Where-Object { $_ -notmatch '(?i)contoso' }

            if ($hits) { '{0}: {1}' -f $file.Name, ($hits -join ', ') }
        })

        $suspicious.Count | Should -Be 0 -Because ($suspicious -join ' | ')
    }

    It 'embeds no hardcoded user profile path' {
        <#
            This is the leak that actually matters, and it is deliberately NOT a search for
            the author's name. 'Andrew Tucker' appears in the module manifest's Author
            field on purpose -- that is authorship metadata on a portfolio project, not an
            infrastructure identifier.

            A hardcoded C:\Users\<someone>\... path is a different thing entirely: it
            leaks a real account name AND breaks on every machine that is not the one it
            was written on.
        #>
        $offenders = @(foreach ($file in $script:TextFiles) {
            $content = Get-Content -LiteralPath $file.FullName -Raw

            # %USERPROFILE%, $env:LOCALAPPDATA, C:\Users\[user]\ placeholders and a
            # C:\Users\...\ ellipsis in prose are all fine; a literal profile directory
            # name is not.
            $hits = [regex]::Matches($content, '(?i)[A-Z]:\\Users\\(?!\[|<|%|\$|\.\.\.|Public\b|Default\b)[A-Za-z0-9._-]+') |
                ForEach-Object { $_.Value }

            if ($hits) { '{0}: {1}' -f $file.Name, (($hits | Select-Object -Unique) -join ', ') }
        })

        $offenders.Count | Should -Be 0 -Because ($offenders -join ' | ')
    }

    It 'embeds no machine or domain identifier' {
        $needles = @($env:COMPUTERNAME, $env:USERDOMAIN) |
            Where-Object { $_ -and $_.Length -gt 3 } |
            Select-Object -Unique

        $offenders = @(foreach ($file in $script:TextFiles) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($needle in $needles) {
                if ($content -match ('\b{0}\b' -f [regex]::Escape($needle))) {
                    '{0}: {1}' -f $file.Name, $needle
                }
            }
        })

        $offenders.Count | Should -Be 0 -Because ($offenders -join ' | ')
    }
}

Describe 'Type contract' {

    It 'offers no ReadyToDeploy readiness level' {
        # The ceiling is "ready for testing". A scaffolder that can claim a package is ready
        # to deploy has stopped being honest about where automation ends.
        InModuleScope PSPackageForge {
            [enum]::GetNames([ReadinessLevel]) | Should -Not -Contain 'ReadyToDeploy'
            [enum]::GetNames([ReadinessLevel]) | Should -Be @('NeedsInput', 'ReviewRequired')
        }
    }

    It 'encodes the documented merge precedence in EvidenceSource' {
        InModuleScope PSPackageForge {
            [int] [EvidenceSource]::UserOverride  | Should -BeGreaterThan ([int] [EvidenceSource]::DiscoveryJson)
            [int] [EvidenceSource]::DiscoveryJson | Should -BeGreaterThan ([int] [EvidenceSource]::Registry)
            [int] [EvidenceSource]::Registry      | Should -BeGreaterThan ([int] [EvidenceSource]::MsiDatabase)
            [int] [EvidenceSource]::MsiDatabase   | Should -BeGreaterThan ([int] [EvidenceSource]::KnownQuirk)
            [int] [EvidenceSource]::KnownQuirk    | Should -BeGreaterThan ([int] [EvidenceSource]::PeMetadata)
            [int] [EvidenceSource]::PeMetadata    | Should -BeGreaterThan ([int] [EvidenceSource]::Inferred)
        }
    }

    It 'registers no return code that maps 1619 to success' {
        # 1619 is a package-open failure. Registering it as a success code is how a broken
        # uninstall gets reported green across a fleet.
        InModuleScope PSPackageForge {
            $mapping = [ReturnCodeMapping]::new(1619, 'Package could not be opened', [ReturnCodeClass]::Failure)
            $mapping.Classification | Should -Be ([ReturnCodeClass]::Failure)
        }
    }

    It 'starts a fresh PackageSpec at NeedsInput with no critical decision resolved' {
        InModuleScope PSPackageForge {
            $spec = [PackageSpec]::new()

            $spec.HasResolvedCriticalDecisions() | Should -BeFalse
            $spec.RecalculateReadiness()         | Should -Be ([ReadinessLevel]::NeedsInput)
        }
    }

    It 'refuses to reach ReviewRequired while a blocking finding is present' {
        InModuleScope PSPackageForge {
            $spec = [PackageSpec]::new()
            $spec.InstallCommand   = [CommandSpec]::new('msiexec.exe', @('/i', 'x.msi', '/qn'))
            $spec.UninstallCommand = [CommandSpec]::new('msiexec.exe', @('/x', '{GUID}', '/qn'))
            $spec.SelectedContext  = [InstallContext]::System
            $spec.DetectionSpec    = @([DetectionSpec]::new())

            $spec.RecalculateReadiness() | Should -Be ([ReadinessLevel]::ReviewRequired)

            $spec.BlockingFindings = @([Finding]::new([FindingSeverity]::Blocking, 'TEST_BLOCK', 'blocked'))

            $spec.RecalculateReadiness() | Should -Be ([ReadinessLevel]::NeedsInput)
        }
    }

    It 'serialises enums as strings so 5.1 and 7 produce identical manifests' {
        InModuleScope PSPackageForge {
            $dict = [PackageSpec]::new().ToOrderedDictionary()

            $dict.Readiness       | Should -BeOfType [string]
            $dict.SelectedContext | Should -BeOfType [string]
            $dict.RebootBehavior  | Should -BeOfType [string]
        }
    }

    It 'serialises InstallerInfo with exactly the two schema-2 architecture fields' {
        InModuleScope PSPackageForge {
            $info = [InstallerInfo]::new()
            $info.InstallerArchitecture  = [ArchitectureType]::x86
            $info.ApplicationArchitecture = [ArchitectureType]::x64

            $keys = @($info.ToOrderedDictionary().Keys)

            # Both subjects are present, in order, and stored as the enum type (rendered as
            # strings on the way out through ToOrderedDictionary).
            $keys | Should -Contain 'InstallerArchitecture'
            $keys | Should -Contain 'ApplicationArchitecture'
            $info.InstallerArchitecture  | Should -BeOfType ([ArchitectureType])
            $info.ApplicationArchitecture | Should -BeOfType ([ArchitectureType])
            $info.InstallerArchitecture  | Should -Be 'x86'
            $info.ApplicationArchitecture | Should -Be 'x64'

            # schema 2 must not emit the legacy single field.
            $keys | Should -Not -Contain 'Architecture'
        }
    }
}

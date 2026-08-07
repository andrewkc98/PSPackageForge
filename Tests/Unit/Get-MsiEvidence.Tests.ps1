<#
    MSI provider tests.

    Two kinds of input are used, deliberately:

      * The committed native-clean.msi fixture, for the real COM read path.
      * Synthetic MsiDatabase objects, for the classification rules.

    The synthetic ones matter most. Wrapper detection, property-token dead ends and
    conditional components are the parts that decide whether the tool emits a confident
    wrong answer, and none of them should require a vendor installer to test. CI never
    downloads vendor binaries (plan §11).
#>

$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

<#
    Test helpers are defined in the global scope on purpose.

    Pester 5 runs It blocks in a different scope from the one the container script body is
    parsed in, so a function declared beside the Describe is not visible inside a test. And
    because these Describes run under InModuleScope, a helper defined in the test file's own
    scope would not be visible from module scope either. Global command lookup is reachable
    from both, so that is where they live. AfterAll removes them again.

    Neither helper touches a module class, so nothing here needs module scope itself.
#>
BeforeAll {
    # A minimal MsiDatabase shaped however a test needs it.
    function global:Get-TestMsiDatabase {
        param(
            [hashtable] $Properties    = @{},
            [hashtable] $Summary       = @{ Template = 'x64;1033' },
            [object[]]  $Files         = @(),
            [object[]]  $Components    = @(),
            [object[]]  $Directories   = @(),
            [object[]]  $Features      = @(),
            [object[]]  $Upgrades      = @(),
            [object[]]  $Binaries      = @(),
            [object[]]  $CustomActions = @()
        )

        [PSCustomObject] @{
            PSTypeName         = 'PSPackageForge.MsiDatabase'
            Path               = 'TestDrive:\synthetic.msi'
            TablesPresent      = @('Property', 'File', 'Component', 'Directory')
            Properties         = $Properties
            SummaryInformation = $Summary
            Files              = $Files
            Components         = $Components
            Directories        = $Directories
            Features           = $Features
            Upgrades           = $Upgrades
            Binaries           = $Binaries
            CustomActions      = $CustomActions
        }
    }

    function global:Get-EvidenceValue {
        param($Result, [string] $Field)
        $record = $Result.Evidence | Where-Object { $_.Field -eq $Field } | Select-Object -First 1
        if ($record) { return $record.Value }
        return $null
    }
}

AfterAll {
    Remove-Item -Path 'function:global:Get-TestMsiDatabase', 'function:global:Get-EvidenceValue' -ErrorAction SilentlyContinue
}

InModuleScope PSPackageForge {


    Describe 'Get-MsiEvidence against the committed native fixture' {

        BeforeAll {
            $script:FixturePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Fixtures\native-clean.msi'
            $script:Result      = Get-MsiEvidence -Path $script:FixturePath
        }

        It 'reads product identity from the Property table' {
            Get-EvidenceValue $script:Result 'ProductName'       | Should -Be 'Fixture Native'
            Get-EvidenceValue $script:Result 'Manufacturer'      | Should -Be 'PSPackageForge Fixtures'
            Get-EvidenceValue $script:Result 'ProductVersionRaw' | Should -Be '1.0.0.0'
            Get-EvidenceValue $script:Result 'ProductCode'       | Should -Be '{B67274A8-A56D-4C2E-B1A0-7A59F5433BD2}'
        }

        It 'classifies a package with real payload and no embedded executable as Native' {
            Get-EvidenceValue $script:Result 'MsiKind'              | Should -Be 'Native'
            Get-EvidenceValue $script:Result 'SupportsMsiUninstall' | Should -BeTrue
        }

        It 'resolves the install path through File -> Component -> Directory' {
            # INSTALLFOLDER -> ProgramFilesFolder -> TARGETDIR
            Get-EvidenceValue $script:Result 'InstallLocation' | Should -Be '%ProgramFiles(x86)%\FixtureNative'
        }

        It 'attributes the install location to the MSI database, at High confidence' {
            $record = $script:Result.Evidence | Where-Object { $_.Field -eq 'InstallLocation' }

            $record.Source     | Should -Be ([EvidenceSource]::MsiDatabase)
            $record.Confidence | Should -Be ([ConfidenceLevel]::High)
        }

        It 'reads architecture from the summary Template, not from the host' {
            # The fixture is an Intel (32-bit) package. The machine running this test is
            # almost certainly x64, so a host-derived answer would be wrong here.
            Get-EvidenceValue $script:Result 'Architecture' | Should -Be 'x86'
        }

        It 'reports that the payload file carries no version instead of inventing one' {
            # dummy.exe is a zero-byte placeholder with no version resource.
            Get-EvidenceValue $script:Result 'DetectionTargetVersion' | Should -BeNullOrEmpty

            $finding = $script:Result.Findings | Where-Object { $_.Code -eq 'MSI_FILE_VERSION_MISSING' }
            $finding | Should -Not -BeNullOrEmpty
        }

        It 'does not leave the MSI file locked' {
            # An unreleased COM wrapper keeps a handle open, and the failure surfaces much
            # later as a sharing violation when something tries to copy the installer.
            { [System.IO.File]::Open($script:FixturePath, 'Open', 'Read', 'None').Dispose() } |
                Should -Not -Throw
        }
    }


    Describe 'Wrapper MSI classification' {

        BeforeAll {
            # Firefox ESR's shape: a ProductCode, zero File rows, one Binary entry, and
            # custom actions of type 3074 running that binary.
            $script:WrapperDatabase = Get-TestMsiDatabase `
                -Properties @{
                    ProductName    = 'Mozilla Firefox 140.13.0esr x64 en-US'
                    ProductVersion = '140.13.0.0'
                    ProductCode    = '{1294A4C5-9977-480F-9497-C0EA1E630130}'
                    Manufacturer   = 'Mozilla'
                } `
                -Files @() `
                -Components @([PSCustomObject] @{ Component = 'EmptyComponent'; Directory = 'TempFolder'; Condition = ''; KeyPath = '' }) `
                -Directories @(
                    [PSCustomObject] @{ Directory = 'TempFolder'; Parent = 'TARGETDIR'; DefaultDir = '.' }
                    [PSCustomObject] @{ Directory = 'TARGETDIR'; Parent = ''; DefaultDir = 'SourceDir' }
                ) `
                -Binaries @('WrappedExe') `
                -CustomActions @(
                    [PSCustomObject] @{ Action = 'RunInstallNoDir'; Type = '3074'; Source = 'WrappedExe'; Target = '/S' }
                )

            $script:WrapperResult = Get-MsiEvidence -Database $script:WrapperDatabase
        }

        It 'classifies an MSI with no File payload as a Wrapper' {
            Get-EvidenceValue $script:WrapperResult 'MsiKind'     | Should -Be 'Wrapper'
            Get-EvidenceValue $script:WrapperResult 'PayloadType' | Should -Be 'Exe'
        }

        It 'reports ProductCode present but msiexec uninstall unsupported' {
            # The whole Firefox regression in one assertion: a ProductCode can exist
            # syntactically without producing the installed-product behaviour MECM expects.
            Get-EvidenceValue $script:WrapperResult 'ProductCodePresent'   | Should -BeTrue
            Get-EvidenceValue $script:WrapperResult 'SupportsMsiUninstall' | Should -BeFalse
        }

        It 'claims NO install location, even though the Directory chain would resolve' {
            <#
                This is the important one. The wrapper's single component points at
                TempFolder, so a naive File -> Component -> Directory walk succeeds and
                returns %TEMP% -- where the payload is EXTRACTED, not where the product is
                INSTALLED. Reporting it would be a confident wrong answer.
            #>
            Get-EvidenceValue $script:WrapperResult 'InstallLocation' | Should -BeNullOrEmpty
            Get-EvidenceValue $script:WrapperResult 'DetectionTarget' | Should -BeNullOrEmpty
        }

        It 'explains why it declined, so the value can be supplied with honest provenance' {
            $finding = $script:WrapperResult.Findings | Where-Object { $_.Code -eq 'MSI_PAYLOAD_NOT_INTROSPECTABLE' }
            $finding | Should -Not -BeNullOrEmpty
        }

        It 'warns that msiexec /x will not work' {
            $finding = $script:WrapperResult.Findings | Where-Object { $_.Code -eq 'MSI_WRAPPER_DETECTED' }

            $finding          | Should -Not -BeNullOrEmpty
            $finding.Severity | Should -Be ([FindingSeverity]::Warning)
        }

        It 'unmasks the custom action base type rather than matching the raw value' {
            # 3074 is type 2 (EXE from Binary) plus deferred and no-impersonate flags.
            Get-MsiCustomActionBaseType -Type '3074' | Should -Be 2
            Get-MsiCustomActionBaseType -Type '2'    | Should -Be 2
            Get-MsiCustomActionBaseType -Type ''     | Should -Be -1
        }

        It 'does not call a package a wrapper merely for having a Binary table' {
            # 7-Zip has four Binary rows -- UI bitmaps -- and is emphatically native.
            # If this heuristic were "Binary table present", 7-Zip would need a quirk
            # entry, and the plan says that would mean the general MSI path is wrong.
            $database = Get-TestMsiDatabase `
                -Properties @{ ProductName = '7-Zip'; ProductCode = '{23170F69-40C1-2702-2602-000001000000}' } `
                -Files @([PSCustomObject] @{ File = '_7z'; Component = 'Main'; FileName = '7z.exe'; FileSize = '600000'; Version = '26.2.0.0' }) `
                -Components @([PSCustomObject] @{ Component = 'Main'; Directory = 'INSTALLDIR'; Condition = ''; KeyPath = '_7z' }) `
                -Directories @(
                    [PSCustomObject] @{ Directory = 'INSTALLDIR'; Parent = 'ProgramFiles64Folder'; DefaultDir = '7-Zip' }
                    [PSCustomObject] @{ Directory = 'ProgramFiles64Folder'; Parent = 'TARGETDIR'; DefaultDir = 'Files' }
                ) `
                -Binaries @('Bitmap1', 'Bitmap2', 'Icon1', 'Icon2') `
                -CustomActions @()

            $result = Get-MsiEvidence -Database $database

            Get-EvidenceValue $result 'MsiKind'              | Should -Be 'Native'
            Get-EvidenceValue $result 'SupportsMsiUninstall' | Should -BeTrue
            Get-EvidenceValue $result 'InstallLocation'      | Should -Be '%ProgramFiles%\7-Zip'
        }

        It 'blocks rather than guessing when a package has payload AND runs an embedded exe' {
            $database = Get-TestMsiDatabase `
                -Properties @{ ProductName = 'Mixed'; ProductCode = '{11111111-1111-1111-1111-111111111111}' } `
                -Files @([PSCustomObject] @{ File = 'f1'; Component = 'C1'; FileName = 'app.exe'; FileSize = '100'; Version = '1.0.0.0' }) `
                -Components @([PSCustomObject] @{ Component = 'C1'; Directory = 'INSTALLDIR'; Condition = ''; KeyPath = 'f1' }) `
                -Directories @(
                    [PSCustomObject] @{ Directory = 'INSTALLDIR'; Parent = 'ProgramFiles64Folder'; DefaultDir = 'Mixed' }
                    [PSCustomObject] @{ Directory = 'ProgramFiles64Folder'; Parent = 'TARGETDIR'; DefaultDir = 'Files' }
                ) `
                -Binaries @('Payload') `
                -CustomActions @([PSCustomObject] @{ Action = 'RunIt'; Type = '3074'; Source = 'Payload'; Target = '/S' })

            $result  = Get-MsiEvidence -Database $database
            $finding = $result.Findings | Where-Object { $_.Code -eq 'MSI_KIND_AMBIGUOUS' }

            $finding.Severity                     | Should -Be ([FindingSeverity]::Blocking)
            Get-EvidenceValue $result 'MsiKind'   | Should -Be 'Unknown'
            Get-EvidenceValue $result 'PayloadType' | Should -Be 'Mixed'
        }
    }


    Describe 'Resolve-MsiInstallPath' {

        It 'maps ProgramFilesFolder to the 32-bit location, per Windows Installer semantics' {
            <#
                On 64-bit Windows ProgramFilesFolder is the 32-bit Program Files for BOTH
                32-bit and 64-bit packages; the 64-bit location is ProgramFiles64Folder.
                Mapping it to C:\Program Files produces a detection rule that never matches.
            #>
            $database = Get-TestMsiDatabase -Directories @(
                [PSCustomObject] @{ Directory = 'APPDIR'; Parent = 'ProgramFilesFolder'; DefaultDir = 'shortnam|My App' }
                [PSCustomObject] @{ Directory = 'ProgramFilesFolder'; Parent = 'TARGETDIR'; DefaultDir = 'PFiles' }
            )

            $result = Resolve-MsiInstallPath -Database $database -DirectoryId 'APPDIR'

            $result.EnvironmentPath | Should -Be '%ProgramFiles(x86)%\My App'
            $result.TokenPath       | Should -Be '[ProgramFilesFolder]\My App'
            $result.Confidence      | Should -Be ([ConfidenceLevel]::High)
        }

        It 'prefers the long name from a short|long DefaultDir pair' {
            $database = Get-TestMsiDatabase -Directories @(
                [PSCustomObject] @{ Directory = 'APPDIR'; Parent = 'ProgramFiles64Folder'; DefaultDir = 'lkwuxpfh|FixtureNative' }
                [PSCustomObject] @{ Directory = 'ProgramFiles64Folder'; Parent = 'TARGETDIR'; DefaultDir = 'Files' }
            )

            (Resolve-MsiInstallPath -Database $database -DirectoryId 'APPDIR').EnvironmentPath |
                Should -Be '%ProgramFiles%\FixtureNative'
        }

        It "treats a DefaultDir of '.' as no directory level" {
            $database = Get-TestMsiDatabase -Directories @(
                [PSCustomObject] @{ Directory = 'SAME'; Parent = 'ProgramFiles64Folder'; DefaultDir = '.' }
                [PSCustomObject] @{ Directory = 'ProgramFiles64Folder'; Parent = 'TARGETDIR'; DefaultDir = 'Files' }
            )

            (Resolve-MsiInstallPath -Database $database -DirectoryId 'SAME').EnvironmentPath |
                Should -Be '%ProgramFiles%'
        }

        It 'downgrades to Medium and raises a finding on a property token' {
            # Plan §8.1: a chain terminating in a property token is Medium at best.
            $database = Get-TestMsiDatabase -Directories @(
                [PSCustomObject] @{ Directory = 'APPDIR'; Parent = 'ProgramFiles64Folder'; DefaultDir = '[INSTALLDIR]' }
                [PSCustomObject] @{ Directory = 'ProgramFiles64Folder'; Parent = 'TARGETDIR'; DefaultDir = 'Files' }
            )

            $result = Resolve-MsiInstallPath -Database $database -DirectoryId 'APPDIR'

            $result.Confidence | Should -Be ([ConfidenceLevel]::Medium)
            ($result.Findings | Where-Object { $_.Code -eq 'MSI_DIRECTORY_PROPERTY_TOKEN' }) | Should -Not -BeNullOrEmpty
        }

        It 'downgrades to Medium when the owning component is conditional' {
            $database = Get-TestMsiDatabase -Directories @(
                [PSCustomObject] @{ Directory = 'APPDIR'; Parent = 'ProgramFiles64Folder'; DefaultDir = 'App' }
                [PSCustomObject] @{ Directory = 'ProgramFiles64Folder'; Parent = 'TARGETDIR'; DefaultDir = 'Files' }
            )

            $result = Resolve-MsiInstallPath -Database $database -DirectoryId 'APPDIR' -ComponentCondition 'VersionNT >= 601'

            $result.Confidence | Should -Be ([ConfidenceLevel]::Medium)
            ($result.Findings | Where-Object { $_.Code -eq 'MSI_COMPONENT_CONDITIONAL' }) | Should -Not -BeNullOrEmpty
        }

        It 'downgrades when the chain terminates at TARGETDIR, whose location is chosen at install time' {
            $database = Get-TestMsiDatabase -Directories @(
                [PSCustomObject] @{ Directory = 'APPDIR'; Parent = 'TARGETDIR'; DefaultDir = 'App' }
                [PSCustomObject] @{ Directory = 'TARGETDIR'; Parent = ''; DefaultDir = 'SourceDir' }
            )

            $result = Resolve-MsiInstallPath -Database $database -DirectoryId 'APPDIR'

            $result.Confidence      | Should -Be ([ConfidenceLevel]::Medium)
            $result.EnvironmentPath | Should -BeNullOrEmpty
            ($result.Findings | Where-Object { $_.Code -eq 'MSI_DIRECTORY_ROOT_UNBOUND' }) | Should -Not -BeNullOrEmpty
        }

        It 'flags a user-profile root as evidence of user scope' {
            $database = Get-TestMsiDatabase -Directories @(
                [PSCustomObject] @{ Directory = 'APPDIR'; Parent = 'LocalAppDataFolder'; DefaultDir = 'Programs' }
                [PSCustomObject] @{ Directory = 'LocalAppDataFolder'; Parent = 'TARGETDIR'; DefaultDir = 'LocalApp' }
            )

            $result = Resolve-MsiInstallPath -Database $database -DirectoryId 'APPDIR'

            $result.IsUserScope     | Should -BeTrue
            $result.EnvironmentPath | Should -Be '%LOCALAPPDATA%\Programs'
        }

        It 'does not hang on a Directory table containing a parent cycle' {
            $database = Get-TestMsiDatabase -Directories @(
                [PSCustomObject] @{ Directory = 'A'; Parent = 'B'; DefaultDir = 'a' }
                [PSCustomObject] @{ Directory = 'B'; Parent = 'A'; DefaultDir = 'b' }
            )

            $result = Resolve-MsiInstallPath -Database $database -DirectoryId 'A'

            $result.Confidence | Should -Be ([ConfidenceLevel]::Low)
            ($result.Findings | Where-Object { $_.Code -eq 'MSI_DIRECTORY_CYCLE' }) | Should -Not -BeNullOrEmpty
        }

        It 'raises a finding when the chain references a directory that is not defined' {
            $database = Get-TestMsiDatabase -Directories @(
                [PSCustomObject] @{ Directory = 'APPDIR'; Parent = 'GhostDirectory'; DefaultDir = 'App' }
            )

            $result = Resolve-MsiInstallPath -Database $database -DirectoryId 'APPDIR'

            $result.Confidence | Should -Be ([ConfidenceLevel]::Medium)
            ($result.Findings | Where-Object { $_.Code -eq 'MSI_DIRECTORY_UNRESOLVED' }) | Should -Not -BeNullOrEmpty
        }
    }


    Describe 'Architecture handling' {

        It 'maps summary Template <Template> to <Expected>' -ForEach @(
            @{ Template = 'Intel;1033'; Expected = 'x86' }
            @{ Template = 'x64;1033';   Expected = 'x64' }
            @{ Template = 'AMD64;1033'; Expected = 'x64' }
            @{ Template = 'Arm64;1033'; Expected = 'Arm64' }
            @{ Template = ';1033';      Expected = 'Neutral' }
        ) {
            $database = Get-TestMsiDatabase -Summary @{ Template = $Template } -Properties @{ ProductName = 'X' }

            Get-EvidenceValue (Get-MsiEvidence -Database $database) 'Architecture' | Should -Be $Expected
        }

        It 'raises a finding instead of guessing when the Template platform is unrecognised' {
            $database = Get-TestMsiDatabase -Summary @{ Template = 'Sparc;1033' } -Properties @{ ProductName = 'X' }
            $result   = Get-MsiEvidence -Database $database

            Get-EvidenceValue $result 'Architecture' | Should -BeNullOrEmpty
            ($result.Findings | Where-Object { $_.Code -eq 'MSI_PLATFORM_UNRECOGNISED' }) | Should -Not -BeNullOrEmpty
        }

        It 'raises a finding when there is no Template at all, rather than assuming x64' {
            $database = Get-TestMsiDatabase -Summary @{} -Properties @{ ProductName = 'X' }
            $result   = Get-MsiEvidence -Database $database

            Get-EvidenceValue $result 'Architecture' | Should -BeNullOrEmpty
            ($result.Findings | Where-Object { $_.Code -eq 'MSI_TEMPLATE_MISSING' }) | Should -Not -BeNullOrEmpty
        }
    }


    Describe 'Install context evidence' {

        It 'reads ALLUSERS=1 as system context, at Medium confidence' {
            # Context is resolved from multiple signals; no single one is proof (plan §8.4).
            $database = Get-TestMsiDatabase -Properties @{ ProductName = 'X'; ALLUSERS = '1' }
            $result   = Get-MsiEvidence -Database $database

            $record = $result.Evidence | Where-Object { $_.Field -eq 'SelectedContext' }

            $record.Value      | Should -Be 'System'
            $record.Confidence | Should -Be ([ConfidenceLevel]::Medium)
        }

        It 'refuses to decide context from ALLUSERS=2' {
            # ALLUSERS=2 means per-machine when elevated, per-user otherwise.
            $database = Get-TestMsiDatabase -Properties @{ ProductName = 'X'; ALLUSERS = '2' }
            $result   = Get-MsiEvidence -Database $database

            Get-EvidenceValue $result 'SelectedContext' | Should -BeNullOrEmpty
            ($result.Findings | Where-Object { $_.Code -eq 'MSI_ALLUSERS_AMBIGUOUS' }) | Should -Not -BeNullOrEmpty
        }

        It 'reads MSIINSTALLPERUSER=1 as user context' {
            $database = Get-TestMsiDatabase -Properties @{ ProductName = 'X'; MSIINSTALLPERUSER = '1' }

            Get-EvidenceValue (Get-MsiEvidence -Database $database) 'SelectedContext' | Should -Be 'User'
        }
    }


    Describe 'Version honesty' {

        It 'records the file version for detection and flags that it differs from ProductVersion' {
            # 7-Zip really does ship ProductVersion 26.02.00.0 with 7z.exe at 26.2.0.0.
            # Detection compares against the file, so the file version is what is recorded.
            $database = Get-TestMsiDatabase `
                -Properties @{ ProductName = '7-Zip'; ProductVersion = '26.02.00.0'; ProductCode = '{23170F69-40C1-2702-2602-000001000000}' } `
                -Files @([PSCustomObject] @{ File = '_7z'; Component = 'Main'; FileName = '7z.exe'; FileSize = '600000'; Version = '26.2.0.0' }) `
                -Components @([PSCustomObject] @{ Component = 'Main'; Directory = 'INSTALLDIR'; Condition = ''; KeyPath = '_7z' }) `
                -Directories @(
                    [PSCustomObject] @{ Directory = 'INSTALLDIR'; Parent = 'ProgramFiles64Folder'; DefaultDir = '7-Zip' }
                    [PSCustomObject] @{ Directory = 'ProgramFiles64Folder'; Parent = 'TARGETDIR'; DefaultDir = 'Files' }
                )

            $result = Get-MsiEvidence -Database $database

            Get-EvidenceValue $result 'ProductVersionRaw'      | Should -Be '26.02.00.0'
            Get-EvidenceValue $result 'DetectionTargetVersion' | Should -Be '26.2.0.0'
            ($result.Findings | Where-Object { $_.Code -eq 'MSI_VERSION_DIFFERS_FROM_FILE' }) | Should -Not -BeNullOrEmpty
        }

        It 'preserves ProductVersionRaw exactly, without padding it to four parts' {
            $database = Get-TestMsiDatabase -Properties @{ ProductName = 'X'; ProductVersion = '1.2' }

            Get-EvidenceValue (Get-MsiEvidence -Database $database) 'ProductVersionRaw' | Should -Be '1.2'
        }
    }
}

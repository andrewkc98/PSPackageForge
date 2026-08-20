<#
    Container detection and dispatch tests (plan section 5.1).

    Get-InstallerContainerType decides which provider even gets a chance to run, and a
    wrong answer there produces a confusing failure two layers away instead of a clean
    finding. The synthetic files below are built byte-by-byte in $TestDrive so the matrix
    does not depend on any committed fixture.

    ConvertFrom-MsiDefaultDir rides along here rather than in Get-MsiEvidence.Tests.ps1
    because it is grammar parsing, not MSI classification -- the DefaultDir mini-language
    is worth its own coverage independent of any Directory table shape.
#>

$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force


InModuleScope PSPackageForge {


    Describe 'Get-InstallerContainerType' {

        It 'identifies <Name> with no extension mismatch' -ForEach @(
            @{ Name = 'an OLE2 compound document under a .msi extension'; Bytes = @(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1); Extension = '.msi';  Expected = [ContainerType]::Msi }
            @{ Name = 'a PE executable under a .exe extension';           Bytes = @(0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00); Extension = '.exe';  Expected = [ContainerType]::Exe }
            @{ Name = 'a ZIP container under a .msix extension';          Bytes = @(0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00); Extension = '.msix'; Expected = [ContainerType]::Msix }
        ) {
            $path = Join-Path $TestDrive ('sample' + $Extension)
            [System.IO.File]::WriteAllBytes($path, [byte[]] $Bytes)

            $result = Get-InstallerContainerType -Path $path

            $result.ContainerType | Should -Be $Expected
            $result.ByContent     | Should -Be $Expected
            $result.ByExtension   | Should -Be $Expected
            $result.Mismatch      | Should -BeFalse
        }

        It 'trusts content over extension: MZ bytes under a .msi name resolve to Exe, flagged as a mismatch' {
            <#
                This is the case the whole function exists for -- a renamed EXE handed to
                the MSI provider fails with an opaque COM error instead of a useful finding.
            #>
            $path = Join-Path $TestDrive 'renamed-installer.msi'
            [System.IO.File]::WriteAllBytes($path, [byte[]] @(0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00))

            $result = Get-InstallerContainerType -Path $path

            $result.ByContent     | Should -Be ([ContainerType]::Exe)
            $result.ByExtension   | Should -Be ([ContainerType]::Msi)
            $result.ContainerType | Should -Be ([ContainerType]::Exe)
            $result.Mismatch      | Should -BeTrue
        }

        It 'reports Unknown when neither content nor extension is recognised' {
            $path = Join-Path $TestDrive 'sample.bin'
            [System.IO.File]::WriteAllBytes($path, [byte[]] @(0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08))

            $result = Get-InstallerContainerType -Path $path

            $result.ContainerType | Should -Be ([ContainerType]::Unknown)
            $result.Mismatch      | Should -BeFalse
        }

        It 'reports Unknown with an empty HeaderHex for a file shorter than 8 bytes' {
            # Extension is deliberately unrecognised too, so byExtension cannot mask the
            # short read: this asserts the short-read path itself, not extension fallback.
            $path = Join-Path $TestDrive 'tiny.bin'
            [System.IO.File]::WriteAllBytes($path, [byte[]] @(0xD0, 0xCF, 0x11))

            $result = Get-InstallerContainerType -Path $path

            $result.ContainerType | Should -Be ([ContainerType]::Unknown)
            $result.ByContent     | Should -Be ([ContainerType]::Unknown)
            $result.HeaderHex     | Should -BeNullOrEmpty
        }
    }


    Describe 'ConvertFrom-MsiDefaultDir' {

        It "extracts '<Expected>' from DefaultDir '<DefaultDir>'" -ForEach @(
            @{ DefaultDir = 'lkwuxpfh|FixtureNative';        Expected = 'FixtureNative' }
            @{ DefaultDir = 'target:source';                 Expected = 'target' }
            @{ DefaultDir = '.';                              Expected = '' }
            @{ DefaultDir = 'short|long:src_short|src_long'; Expected = 'long' }
            @{ DefaultDir = '';                               Expected = '' }
            @{ DefaultDir = $null;                            Expected = '' }
        ) {
            ConvertFrom-MsiDefaultDir -DefaultDir $DefaultDir | Should -Be $Expected
        }
    }
}


<#
    Dispatch is exercised through the real public command, outside InModuleScope, the same
    way Tests\Integration\Get-InstallerInfo.Tests.ps1 does -- these are the branches a
    caller who only ran Import-Module actually observes.
#>
Describe 'Get-InstallerInfo container dispatch' {

    BeforeAll {
        $script:ModuleRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:ManifestPath = Join-Path $script:ModuleRoot 'PSPackageForge.psd1'
        Import-Module $script:ManifestPath -Force
    }

    It 'dispatches a PE executable to the Exe branch, and blocks because framework analysis is not implemented yet' {
        $path = Join-Path $TestDrive 'setup.exe'
        [System.IO.File]::WriteAllBytes($path, [byte[]] @(0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00))

        $result = Get-InstallerInfo -Path $path

        $result.ContainerType | Should -Be 'Exe'

        $finding = $result.Findings | Where-Object { $_.Code -eq 'EXE_ANALYSIS_NOT_IMPLEMENTED' }
        $finding                | Should -Not -BeNullOrEmpty
        $finding.Severity.ToString() | Should -Be 'Blocking'
    }

    It 'dispatches a ZIP-based package to the Msix branch, and blocks it as out of scope for v1' {
        $path = Join-Path $TestDrive 'package.msix'
        [System.IO.File]::WriteAllBytes($path, [byte[]] @(0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00))

        $result = Get-InstallerInfo -Path $path

        $result.ContainerType | Should -Be 'Msix'

        $finding = $result.Findings | Where-Object { $_.Code -eq 'MSIX_OUT_OF_SCOPE' }
        $finding                | Should -Not -BeNullOrEmpty
        $finding.Severity.ToString() | Should -Be 'Blocking'
    }

    It 'blocks with CONTAINER_UNKNOWN when the file matches no known container format' {
        $path = Join-Path $TestDrive 'mystery.dat'
        [System.IO.File]::WriteAllBytes($path, [byte[]] @(0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08))

        $result = Get-InstallerInfo -Path $path

        $result.ContainerType | Should -Be 'Unknown'

        $finding = $result.Findings | Where-Object { $_.Code -eq 'CONTAINER_UNKNOWN' }
        $finding                | Should -Not -BeNullOrEmpty
        $finding.Severity.ToString() | Should -Be 'Blocking'
    }
}

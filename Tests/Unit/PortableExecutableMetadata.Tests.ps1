$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {
    Describe 'Read-PortableExecutableData' {
        BeforeAll {
            $script:FixtureRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Fixtures/framework-stubs'
        }

        It 'maps machine types and parses section names' {
            $r = Read-PortableExecutableData -Path (Join-Path $script:FixtureRoot 'wix-burn.exe')
            $r.Architecture | Should -Be 'x64'
            $r.SectionNames | Should -Contain '.wixburn'
            $r.Machine | Should -Be '0x8664'
        }

        It 'finds ASCII and UTF-16LE markers across chunk boundaries' {
            $r = Read-PortableExecutableData -Path (Join-Path $script:FixtureRoot 'nsis.exe') -AsciiMarkers 'NullsoftInst' -ChunkSize 64
            $r.AsciiMarkersFound | Should -Contain 'NullsoftInst'
            $unicodePath = Join-Path $TestDrive 'unicode-marker.exe'
            $bytes = [IO.File]::ReadAllBytes((Join-Path $script:FixtureRoot 'unknown.exe'))
            $marker = [Text.Encoding]::Unicode.GetBytes('Inno Setup Setup Data')
            [Array]::Copy($marker, 0, $bytes, 0x520, $marker.Length)
            [IO.File]::WriteAllBytes($unicodePath, $bytes)
            $r = Read-PortableExecutableData -Path $unicodePath -Utf16LEMarkers 'Inno Setup Setup Data' -ChunkSize 64
            $r.Utf16LEMarkersFound | Should -Contain 'Inno Setup Setup Data'
        }

        It 'returns unknown architecture for an unknown machine' {
            (Read-PortableExecutableData -Path (Join-Path $script:FixtureRoot 'unknown.exe')).Architecture | Should -Be 'x86'
            (Read-PortableExecutableData -Path (Join-Path $script:FixtureRoot 'installshield.exe')).Architecture | Should -Be 'Arm64'
            $unsupportedPath = Join-Path $TestDrive 'unknown-machine.exe'
            $unsupportedBytes = [IO.File]::ReadAllBytes((Join-Path $script:FixtureRoot 'unknown.exe'))
            $peOffset = [BitConverter]::ToInt32($unsupportedBytes, 0x3C)
            $unsupportedBytes[$peOffset + 4] = 0xFF
            $unsupportedBytes[$peOffset + 5] = 0xFF
            [IO.File]::WriteAllBytes($unsupportedPath, $unsupportedBytes)
            (Read-PortableExecutableData -Path $unsupportedPath).Architecture | Should -Be 'Unknown'
        }

        It 'rejects malformed and truncated files and remains usable afterward' {
            { Read-PortableExecutableData -Path (Join-Path $script:FixtureRoot 'truncated.exe') } | Should -Throw '*truncated*'
            { Read-PortableExecutableData -Path (Join-Path $script:FixtureRoot 'malformed.exe') } | Should -Throw
            { Read-PortableExecutableData -Path (Join-Path $script:FixtureRoot 'squirrel.exe') } | Should -Not -Throw
        }

        It 'handles absent version metadata defensively' {
            $r = Read-PortableExecutableData -Path (Join-Path $script:FixtureRoot 'unknown.exe')
            $r.FileVersionInfo | Should -Not -BeNullOrEmpty
            $r.FileVersionInfo.FileVersion | Should -BeNullOrEmpty
        }
    }
}

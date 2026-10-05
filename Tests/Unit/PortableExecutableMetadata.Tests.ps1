$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {
    Describe 'Read-PortableExecutableData' {
        BeforeAll {
            $script:FixtureRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Fixtures/framework-stubs'
        }

        It 'matches in-memory byte patterns with the original case-sensitive boundaries' {
            (Find-PortableMarker -Haystack ([byte[]](1, 2, 3, 4, 5)) -Needle ([byte[]](1, 2))) | Should -BeTrue
            (Find-PortableMarker -Haystack ([byte[]](1, 2, 3, 4, 5)) -Needle ([byte[]](4, 5))) | Should -BeTrue
            (Find-PortableMarker -Haystack ([byte[]](1, 2, 3, 4, 5)) -Needle ([byte[]](2, 4))) | Should -BeFalse
            (Find-PortableMarker -Haystack ([byte[]](78, 117, 108, 108, 115, 111, 102, 116)) -Needle ([Text.Encoding]::ASCII.GetBytes('Nullsoft'))) | Should -BeTrue
            (Find-PortableMarker -Haystack ([Text.Encoding]::Unicode.GetBytes('Inno Setup')) -Needle ([Text.Encoding]::Unicode.GetBytes('Inno'))) | Should -BeTrue
            (Find-PortableMarker -Haystack ([Text.Encoding]::ASCII.GetBytes('Nullsoft')) -Needle ([Text.Encoding]::ASCII.GetBytes('nullsoft'))) | Should -BeFalse
            (Find-PortableMarker -Haystack ([byte[]](1, 2)) -Needle ([byte[]](1, 2, 3))) | Should -BeFalse
            (Find-PortableMarker -Haystack ([byte[]](1, 2)) -Needle ([byte[]]@())) | Should -BeFalse
        }

        It 'finds a marker that overlaps two in-memory chunks' {
            $needle = [byte[]](0x41, 0x42, 0x43, 0x44)
            $chunks = [System.Collections.Generic.List[byte[]]]::new()
            $chunks.Add([byte[]](0x10, 0x11, 0x41, 0x42))
            $chunks.Add([byte[]](0x43, 0x44, 0x12))
            $carry = [byte[]]@()
            $found = $false
            foreach ($chunk in $chunks) {
                $combined = New-Object byte[] ($carry.Length + $chunk.Length)
                if ($carry.Length) { [Array]::Copy($carry, $combined, $carry.Length) }
                [Array]::Copy($chunk, 0, $combined, $carry.Length, $chunk.Length)
                if (Find-PortableMarker -Haystack $combined -Needle $needle) { $found = $true }
                $keep = [Math]::Min($needle.Length - 1, $combined.Length)
                $carry = if ($keep) { $combined[($combined.Length - $keep)..($combined.Length - 1)] } else { [byte[]]@() }
            }
            $found | Should -BeTrue
        }

        It 'imports twice in a fresh PowerShell process and invokes the compiled matcher' {
            $moduleRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
            $moduleManifest = Join-Path $moduleRoot 'PSPackageForge.psd1'
            $escapedManifest = $moduleManifest.Replace("'", "''")
            $childScript = @"
`$ErrorActionPreference = 'Stop'
Import-Module -Name '$escapedManifest' -Force
Import-Module -Name '$escapedManifest' -Force
if ('PSPackageForge.Internal.PortableMarkerMatcher' -as [type]) { exit 20 }
`$module = Get-Module -Name PSPackageForge
`$matched = & `$module { Find-PortableMarker -Haystack ([byte[]](0x10, 0x41, 0x42, 0x20)) -Needle ([byte[]](0x41, 0x42)) }
if (-not `$matched) { exit 21 }
`$matcherType = 'PSPackageForge.Internal.PortableMarkerMatcher' -as [type]
if (`$null -eq `$matcherType) { exit 22 }
exit 0
"@
            $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
            $enginePath = (Get-Process -Id $PID | Select-Object -First 1 -ExpandProperty Path)
            $enginePath | Should -Not -BeNullOrEmpty
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $enginePath
            $startInfo.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encodedScript"
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            $null = $process.Start()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) { throw "Fresh-process import failed with exit code $($process.ExitCode). stdout: $stdout stderr: $stderr" }
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

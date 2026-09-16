<#
    Contract tests for the authoritative manifest reader. Fixtures intentionally use nested
    PSADT-shaped metadata so similarly named keys in unrelated sections are not mistaken for
    the Generator or PackageSpec fields.
#>
$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {
    BeforeAll {
        $script:FixtureRoot = Join-Path $TestDrive 'manifest-reader'
        [void] (New-Item -ItemType Directory -Path $script:FixtureRoot -Force)

        function Use-ReaderFixture {
            param([string] $Readiness = 'ReviewRequired')
            $root = Join-Path $script:FixtureRoot ([Guid]::NewGuid().ToString('N'))
            [void] (New-Item -ItemType Directory -Path $root -Force)
            $installerPath = Join-Path $root 'setup.exe'
            Set-Content -LiteralPath $installerPath -Value 'read-only fixture bytes' -NoNewline -Encoding UTF8
            $installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
            $manifest = [ordered] @{
                SchemaVersion = '2.0'
                Generator = [ordered] @{
                    Name = 'PSPackageForge'
                    Version = '0.2.0'
                    RequiredPSADTVersion = '4.0.6'
                    NestedPSADT = [ordered] @{ Name = 'OtherTool'; Version = '9.9.9' }
                }
                Installer = [ordered] @{
                    Path = 'setup.exe'
                    FileName = 'setup.exe'
                    SHA256 = $installerHash
                    NestedPSADT = [ordered] @{ RequiredPSADTVersion = '99.0.0' }
                }
                PackageSpec = [ordered] @{
                    InstallCommand = [ordered] @{
                        Executable = 'setup.exe'
                        ArgumentList = @('/quiet')
                        ExpectedExitCodes = @(0, 3010)
                    }
                    UninstallCommand = [ordered] @{
                        Executable = 'setup.exe'
                        ArgumentList = @('/uninstall', '/quiet')
                        ExpectedExitCodes = @(0, 3010)
                    }
                    ReturnCodeMap = @(
                        [ordered] @{ Code = 0; Classification = 'Success'; Meaning = 'Success' }
                        [ordered] @{ Code = 3010; Classification = 'SuccessRebootRequired'; Meaning = 'Reboot' }
                    )
                    NestedPSADT = [ordered] @{ Name = 'DoNotRead'; RequiredPSADTVersion = '88.0.0' }
                }
                Readiness = $Readiness
            }
            $manifestPath = Join-Path $root 'PackageManifest.json'
            $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
            [pscustomobject] @{ Root = $root; ManifestPath = $manifestPath; Manifest = $manifest; InstallerPath = $installerPath }
        }

        function Write-ReaderManifest {
            param([object] $Fixture, [object] $Manifest)
            $Manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Fixture.ManifestPath -Encoding UTF8
        }
    }

    Describe 'Read-PackageForgeManifest' {
        It 'returns canonical paths, the parsed manifest, normalized PSADT version, and hashes without writes' {
            $fixture = Use-ReaderFixture
            $beforeManifestHash = (Get-FileHash -LiteralPath $fixture.ManifestPath -Algorithm SHA256).Hash
            $beforeInstallerHash = (Get-FileHash -LiteralPath $fixture.InstallerPath -Algorithm SHA256).Hash

            $result = Read-PackageForgeManifest -ManifestPath (Join-Path -Path (Join-Path -Path $fixture.Root -ChildPath '.') -ChildPath 'PackageManifest.json')

            $result.ManifestPath | Should -Be ([System.IO.Path]::GetFullPath($fixture.ManifestPath))
            $result.ScaffoldRoot | Should -Be ([System.IO.Path]::GetFullPath($fixture.Root))
            $result.InstallerPath | Should -Be ([System.IO.Path]::GetFullPath($fixture.InstallerPath))
            $result.ManifestSHA256 | Should -Be $beforeManifestHash
            $result.RequiredPSADTVersion | Should -Be '4.0.6'
            $result.Manifest.Generator.NestedPSADT.Name | Should -Be 'OtherTool'
            (Get-FileHash -LiteralPath $fixture.ManifestPath -Algorithm SHA256).Hash | Should -Be $beforeManifestHash
            (Get-FileHash -LiteralPath $fixture.InstallerPath -Algorithm SHA256).Hash | Should -Be $beforeInstallerHash
        }

        It 'parses NeedsInput for review while rejecting it for a runnable consumer' {
            $fixture = Use-ReaderFixture -Readiness 'NeedsInput'
            $fixture.Manifest.PackageSpec.InstallCommand = $null
            $fixture.Manifest.PackageSpec.UninstallCommand = $null
            Write-ReaderManifest -Fixture $fixture -Manifest $fixture.Manifest
            { Read-PackageForgeManifest -ManifestPath $fixture.ManifestPath } | Should -Not -Throw
            { Read-PackageForgeManifest -ManifestPath $fixture.ManifestPath -RequireRunnable } |
                Should -Throw "*readiness is 'NeedsInput'*"
        }

        It 'accepts empty and single-element string arrays and reordered JSON properties' {
            $fixture = Use-ReaderFixture
            $json = @'
{
  "Readiness": "ReviewRequired",
  "PackageSpec": {
    "ReturnCodeMap": [ { "Classification": "Success", "Code": 0 }, { "Classification": "SuccessRebootRequired", "Code": 3010 } ],
    "UninstallCommand": { "ExpectedExitCodes": [0], "ArgumentList": [""], "Executable": "setup.exe" },
    "InstallCommand": { "ExpectedExitCodes": [0, 3010], "ArgumentList": [], "Executable": "setup.exe" }
  },
  "Installer": { "SHA256": "HASH", "FileName": "setup.exe", "Path": "setup.exe" },
  "Generator": { "RequiredPSADTVersion": "4.0.6", "Version": "0.2.0", "Name": "PSPackageForge" },
  "SchemaVersion": "2.0"
}
'@
            $json = $json.Replace('HASH', $fixture.Manifest.Installer.SHA256)
            Set-Content -LiteralPath $fixture.ManifestPath -Value $json -Encoding UTF8
            { Read-PackageForgeManifest -ManifestPath $fixture.ManifestPath } | Should -Not -Throw
        }

        It 'rejects malformed JSON, wrong schema, and generator metadata' {
            $fixture = Use-ReaderFixture
            Set-Content -LiteralPath $fixture.ManifestPath -Value '{' -Encoding UTF8
            { Read-PackageForgeManifest $fixture.ManifestPath } | Should -Throw '*malformed JSON*'
            $fixture = Use-ReaderFixture
            $fixture.Manifest.SchemaVersion = '1.0'; Write-ReaderManifest $fixture $fixture.Manifest
            { Read-PackageForgeManifest $fixture.ManifestPath } | Should -Throw '*expected ''2.0''*'
            foreach ($property in @('Name', 'Version', 'RequiredPSADTVersion')) {
                $fixture = Use-ReaderFixture
                $fixture.Manifest.Generator.$property = if ($property -eq 'Name') { 'Other' } elseif ($property -eq 'Version') { '0.1.0' } else { '4.0.5' }
                Write-ReaderManifest $fixture $fixture.Manifest
                { Read-PackageForgeManifest -ManifestPath $fixture.ManifestPath -RequireRunnable } | Should -Throw
            }
        }

        It 'rejects unsupported readiness, direct-child violations, bad hashes, and staged changes' {
            $cases = @(
                @{ Change = { param($m) $m.Readiness = 'ReadyToDeploy' }; Error = 'readiness' }
                @{ Change = { param($m) $m.Installer.Path = 'sub/setup.exe' }; Error = 'direct child' }
                @{ Change = { param($m) $m.Installer.FileName = 'other.exe' }; Error = 'direct child' }
                @{ Change = { param($m) $m.Installer.SHA256 = 'not-a-hash' }; Error = '64 hexadecimal' }
            )
            foreach ($case in $cases) {
                $fixture = Use-ReaderFixture
                & $case.Change $fixture.Manifest
                Write-ReaderManifest $fixture $fixture.Manifest
                { Read-PackageForgeManifest $fixture.ManifestPath } | Should -Throw "*$($case.Error)*"
            }
            $fixture = Use-ReaderFixture
            Add-Content -LiteralPath $fixture.InstallerPath -Value 'changed'
            { Read-PackageForgeManifest $fixture.ManifestPath } | Should -Throw '*hash mismatch*'
        }

        It 'rejects missing or unresolved structured commands and incomplete return-code coverage' {
            $mutations = @(
                { param($m) $m.PackageSpec.InstallCommand = $null }
                { param($m) $m.PackageSpec.InstallCommand.Executable = '' }
                { param($m) $m.PackageSpec.InstallCommand.ExpectedExitCodes = @() }
                { param($m) $m.PackageSpec.InstallCommand.ExpectedExitCodes = @(1618) }
                { param($m) $m.PackageSpec.ReturnCodeMap = @([ordered] @{ Code = 0; Classification = 'Success' }) }
            )
            foreach ($mutation in $mutations) {
                $fixture = Use-ReaderFixture
                & $mutation $fixture.Manifest
                Write-ReaderManifest $fixture $fixture.Manifest
                { Read-PackageForgeManifest -ManifestPath $fixture.ManifestPath -RequireRunnable } | Should -Throw
            }
            $reviewFixture = Use-ReaderFixture
            $reviewFixture.Manifest.PackageSpec.InstallCommand = $null
            Write-ReaderManifest -Fixture $reviewFixture -Manifest $reviewFixture.Manifest
            { Read-PackageForgeManifest -ManifestPath $reviewFixture.ManifestPath } | Should -Throw
        }

        It 'rejects malformed command shapes, non-integer codes, duplicate mappings, and failure classifications' {
            $mutations = @(
                { param($m) $m.PackageSpec.InstallCommand = 'setup.exe /quiet' }
                { param($m) $m.PackageSpec.InstallCommand.ArgumentList = '/quiet' }
                { param($m) $m.PackageSpec.InstallCommand.ArgumentList = @('/quiet', [pscustomobject] @{ Value = 'bad' }) }
                { param($m) $m.PackageSpec.InstallCommand.WorkingDirectory = [pscustomobject] @{ Path = 'bad' } }
                { param($m) $m.PackageSpec.InstallCommand.ExpectedExitCodes = @(1.2) }
                { param($m) $m.PackageSpec.InstallCommand.ExpectedExitCodes = @($true) }
                { param($m) $m.PackageSpec.ReturnCodeMap[0].Classification = 'Failure' }
                { param($m) $m.PackageSpec.ReturnCodeMap += [ordered] @{ Code = 3010; Classification = 'Success' } }
            )
            foreach ($mutation in $mutations) {
                $fixture = Use-ReaderFixture
                & $mutation $fixture.Manifest
                Write-ReaderManifest -Fixture $fixture -Manifest $fixture.Manifest
                { Read-PackageForgeManifest -ManifestPath $fixture.ManifestPath } | Should -Throw
            }
        }

        It 'rejects missing required metadata and a missing staged installer' {
            foreach ($property in @('SchemaVersion', 'Generator', 'Installer', 'PackageSpec', 'Readiness')) {
                $fixture = Use-ReaderFixture
                [void] $fixture.Manifest.Remove($property)
                Write-ReaderManifest -Fixture $fixture -Manifest $fixture.Manifest
                { Read-PackageForgeManifest -ManifestPath $fixture.ManifestPath } | Should -Throw
            }
            $fixture = Use-ReaderFixture
            Remove-Item -LiteralPath $fixture.InstallerPath
            { Read-PackageForgeManifest -ManifestPath $fixture.ManifestPath } | Should -Throw '*staged installer*'
        }

        It 'rejects the reserved minimum Int32 exit code anywhere in commands or mappings' {
            foreach ($mutation in @(
                    { param($m) $m.PackageSpec.InstallCommand.ExpectedExitCodes = @(-2147483648) }
                    { param($m) $m.PackageSpec.ReturnCodeMap += [ordered] @{ Code = -2147483648; Classification = 'Failure' } }
                )) {
                $fixture = Use-ReaderFixture
                & $mutation $fixture.Manifest
                Write-ReaderManifest $fixture $fixture.Manifest
                { Read-PackageForgeManifest $fixture.ManifestPath } | Should -Throw '*reserved exit code*'
            }
        }
    }
}

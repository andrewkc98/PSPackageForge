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
        BeforeAll {
            # Pester scopes functions declared by a container's BeforeAll separately from
            # sibling containers, so define these helpers at the consuming Describe scope.
            function Use-ReaderFixture {
                param([string] $Readiness = 'ReviewRequired')
                $root = Join-Path $script:FixtureRoot ([Guid]::NewGuid().ToString('N'))
                [void] (New-Item -ItemType Directory -Path $root -Force)
                $installerPath = Join-Path $root 'setup.exe'
                Set-Content -LiteralPath $installerPath -Value 'read-only fixture bytes' -NoNewline -Encoding UTF8
                $installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
                $manifest = [ordered] @{
                    SchemaVersion = '2.0'
                    Generator = [ordered] @{ Name = 'PSPackageForge'; Version = '0.2.0'; RequiredPSADTVersion = '4.0.6'; NestedPSADT = [ordered] @{ Name = 'OtherTool'; Version = '9.9.9' } }
                    Installer = [ordered] @{ Path = 'setup.exe'; FileName = 'setup.exe'; SHA256 = $installerHash; NestedPSADT = [ordered] @{ RequiredPSADTVersion = '99.0.0' } }
                    PackageSpec = [ordered] @{
                        InstallCommand = [ordered] @{ Executable = 'setup.exe'; ArgumentList = @('/quiet'); ExpectedExitCodes = @(0, 3010) }
                        UninstallCommand = [ordered] @{ Executable = 'setup.exe'; ArgumentList = @('/uninstall', '/quiet'); ExpectedExitCodes = @(0, 3010) }
                        ReturnCodeMap = @(
                            [ordered] @{ Code = 0; Classification = 'Success'; Meaning = 'Success' }
                            [ordered] @{ Code = 3010; Classification = 'SuccessRebootRequired'; Meaning = 'Reboot' })
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

InModuleScope PSPackageForge {
    Describe 'Write-PackageForgeReceipt' {
        BeforeAll { . (Join-Path $ModuleRoot 'Tests/Fixtures/New-PackageValidationFixture.ps1') }
        It 'writes metadata and an ordinally sorted inventory with hashes and lengths' {
            $fixture = New-PackageValidationFixture -RootPath (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
            $nested = Join-Path $fixture.PackagePath 'Files/nested/.dotfile'
            [void] (New-Item -ItemType Directory -Path (Split-Path $nested -Parent) -Force)
            Set-Content -LiteralPath $nested -Value 'dot' -NoNewline -Encoding UTF8
            $receiptPath = Write-PackageForgeReceipt -ManifestInput $fixture.ManifestInput -PackagePath $fixture.PackagePath
            $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
            $receipt.SchemaVersion | Should -Be '1.0'
            $receipt.Generator.Name | Should -Be 'PSPackageForge'
            $receipt.Renderer.Name | Should -Be 'PSADT'
            $receipt.SourceManifest.FileName | Should -Be 'PackageManifest.json'
            $receipt.Toolkit.ModuleManifestPath | Should -Be 'PSAppDeployToolkit/PSAppDeployToolkit.psd1'
            @($receipt.Files.Path) | Should -Be @('Config/config.psd1', 'Files/nested/.dotfile', 'Files/setup.exe', 'Invoke-AppDeployToolkit.exe', 'Invoke-AppDeployToolkit.ps1', 'PSAppDeployToolkit/PSAppDeployToolkit.psd1')
            $setup = @($receipt.Files | Where-Object Path -eq 'Files/setup.exe')[0]
            $setup.Length | Should -Be ((Get-Item (Join-Path $fixture.PackagePath 'Files/setup.exe')).Length)
            $setup.SHA256 | Should -Be (Get-FileHash (Join-Path $fixture.PackagePath 'Files/setup.exe') -Algorithm SHA256).Hash
            $receipt.Files.Path | Should -Not -Contain 'PSPackageForgeReceipt.json'
        }

        It 'produces the same receipt content apart from GeneratedAtUtc for equivalent trees' {
            $first = New-PackageValidationFixture -RootPath (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
            $second = New-PackageValidationFixture -RootPath (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
            $firstReceipt = Get-Content -LiteralPath (Write-PackageForgeReceipt $first.ManifestInput $first.PackagePath) -Raw | ConvertFrom-Json
            $secondReceipt = Get-Content -LiteralPath (Write-PackageForgeReceipt $second.ManifestInput $second.PackagePath) -Raw | ConvertFrom-Json
            $firstReceipt.GeneratedAtUtc = $null
            $secondReceipt.GeneratedAtUtc = $null
            ($firstReceipt | ConvertTo-Json -Depth 10) | Should -Be ($secondReceipt | ConvertTo-Json -Depth 10)
        }

        It 'fails before creating a receipt for wrong toolkit or each missing required file' {
            foreach ($case in @(
                    @{ RelativePath = 'PSAppDeployToolkit/PSAppDeployToolkit.psd1'; Content = "@{ ModuleVersion = '4.0.5' }"; Error = 'version' }
                    @{ RelativePath = 'Invoke-AppDeployToolkit.exe'; Content = $null; Error = 'root launcher' }
                    @{ RelativePath = 'Invoke-AppDeployToolkit.ps1'; Content = $null; Error = 'frontend' }
                    @{ RelativePath = 'Config/config.psd1'; Content = $null; Error = 'configuration' }
                    @{ RelativePath = 'PSAppDeployToolkit/PSAppDeployToolkit.psd1'; Content = $null; Error = 'bundled toolkit manifest' }
                    @{ RelativePath = 'Files/setup.exe'; Content = $null; Error = 'packaged installer' })) {
                $fixture = New-PackageValidationFixture -RootPath (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')))
                $path = Join-Path $fixture.PackagePath ($case.RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
                if ($null -eq $case.Content) { Remove-Item -LiteralPath $path -Force } else { Set-Content -LiteralPath $path -Value $case.Content -Encoding UTF8 }
                { Write-PackageForgeReceipt -ManifestInput $fixture.ManifestInput -PackagePath $fixture.PackagePath } | Should -Throw "*$($case.Error)*"
                (Join-Path $fixture.PackagePath 'PSPackageForgeReceipt.json') | Should -Not -Exist
            }
        }
    }

    Describe 'Test-PackageForgePackage' {
        BeforeAll { . (Join-Path $ModuleRoot 'Tests/Fixtures/New-PackageValidationFixture.ps1') }
        It 'returns canonical package component paths for a valid package' {
            $fixture = New-PackageValidationFixture -RootPath (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) -CreateReceipt
            $result = Test-PackageForgePackage -ManifestInput $fixture.ManifestInput -PackagePath $fixture.PackagePath
            $result.PackagePath | Should -Be ([System.IO.Path]::GetFullPath($fixture.PackagePath))
            $result.LauncherPath | Should -Be (Join-Path $result.PackagePath 'Invoke-AppDeployToolkit.exe')
            $result.FrontendPath | Should -Be (Join-Path $result.PackagePath 'Invoke-AppDeployToolkit.ps1')
            $result.ConfigPath | Should -Be (Join-Path $result.PackagePath 'Config/config.psd1')
            $result.ToolkitManifestPath | Should -Be (Join-Path $result.PackagePath 'PSAppDeployToolkit/PSAppDeployToolkit.psd1')
            $result.PayloadPath | Should -Be (Join-Path $result.PackagePath 'Files/setup.exe')
        }

        It 'rejects each stale or incomplete matrix case without writing to the package' {
            $cases = @(
                @{ Name = 'stale manifest commands'; Change = { param($f) $m = $f.ManifestInput.Manifest; $m.PackageSpec.InstallCommand.ArgumentList = @('/changed'); $m | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $f.ManifestInput.ManifestPath -Encoding UTF8 } }
                @{ Name = 'changed toolkit requirement'; Change = { param($f) $f.ManifestInput.RequiredPSADTVersion = '4.0.5' } }
                @{ Name = 'missing toolkit module file'; Change = { param($f) Remove-Item -LiteralPath (Join-Path $f.PackagePath 'PSAppDeployToolkit/PSAppDeployToolkit.psm1') } }
                @{ Name = 'missing launcher'; Change = { param($f) Remove-Item -LiteralPath (Join-Path $f.PackagePath 'Invoke-AppDeployToolkit.exe') } }
                @{ Name = 'placeholder launcher'; Change = { param($f) Set-Content -LiteralPath (Join-Path $f.PackagePath 'Invoke-AppDeployToolkit.exe') -Value 'launcher' -NoNewline } }
                @{ Name = 'missing frontend'; Change = { param($f) Remove-Item -LiteralPath (Join-Path $f.PackagePath 'Invoke-AppDeployToolkit.ps1') } }
                @{ Name = 'placeholder frontend'; Change = { param($f) Set-Content -LiteralPath (Join-Path $f.PackagePath 'Invoke-AppDeployToolkit.ps1') -Value 'frontend' -NoNewline } }
                @{ Name = 'extra file'; Change = { param($f) Set-Content -LiteralPath (Join-Path $f.PackagePath 'unexpected.txt') -Value 'extra' -NoNewline } }
                @{ Name = 'changed bytes'; Change = { param($f) Add-Content -LiteralPath (Join-Path $f.PackagePath 'Files/setup.exe') -Value 'changed' -NoNewline } }
                @{ Name = 'wrong receipt renderer version'; Change = { param($f) $p = Join-Path $f.PackagePath 'PSPackageForgeReceipt.json'; $r = Get-Content $p -Raw | ConvertFrom-Json; $r.Renderer.Version = '0.1.0'; $r | ConvertTo-Json -Depth 10 | Set-Content $p -Encoding UTF8 } }
            )
            foreach ($case in $cases) {
                $fixture = New-PackageValidationFixture -RootPath (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) -CreateReceipt
                & $case.Change $fixture
                $before = @(Get-ChildItem -LiteralPath $fixture.PackagePath -File -Recurse -Force | ForEach-Object {
                    [pscustomobject] @{ Path = $_.FullName; Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
                })
                { Test-PackageForgePackage -ManifestInput $fixture.ManifestInput -PackagePath $fixture.PackagePath } | Should -Throw
                $after = @(Get-ChildItem -LiteralPath $fixture.PackagePath -File -Recurse -Force | ForEach-Object {
                    [pscustomobject] @{ Path = $_.FullName; Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
                })
                ($after | ConvertTo-Json -Depth 3) | Should -Be ($before | ConvertTo-Json -Depth 3)
            }
        }
    }
}

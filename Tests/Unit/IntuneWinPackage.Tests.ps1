$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {
    Describe 'Resolve-IntuneWinAppUtil' {
        BeforeEach {
            $script:repo = Join-Path $TestDrive 'repo'
            $settingsPath = Join-Path $script:repo 'Config/settings.psd1'
            if (Test-Path -LiteralPath $settingsPath) { Remove-Item -LiteralPath $settingsPath -Force }
            [void](New-Item -ItemType Directory -Path (Join-Path $script:repo 'Config') -Force)
            $script:explicit = Join-Path $TestDrive 'explicit.exe'
            Set-Content -LiteralPath $script:explicit -Value 'tool' -NoNewline
        }

        It 'uses an explicit existing leaf before settings and PATH' {
            $settings = Join-Path $script:repo 'Config/settings.psd1'
            Set-Content -LiteralPath $settings -Value "@{ IntuneWinAppUtilPath = 'missing.exe' }"
            Mock Get-Command { @() }

            $result = Resolve-IntuneWinAppUtil -ExplicitPath $script:explicit -RepositoryRoot $script:repo

            $result.ToolAvailable | Should -BeTrue
            $result.IntuneWinAppUtilPath | Should -Be ([System.IO.Path]::GetFullPath($script:explicit))
            $result.Source | Should -Be 'Explicit'
            Should -Invoke Get-Command -Times 0 -Exactly
        }

        It 'terminates for an invalid explicit path' {
            { Resolve-IntuneWinAppUtil -ExplicitPath (Join-Path $TestDrive 'missing.exe') -RepositoryRoot $script:repo } |
                Should -Throw '*explicitly supplied*existing leaf file*'
        }

        It 'uses a valid configured path and does not fall through to PATH' {
            $configured = Join-Path $script:repo 'Config/tool.exe'
            Set-Content -LiteralPath $configured -Value 'tool' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:repo 'Config/settings.psd1') `
                -Value "@{ IntuneWinAppUtilPath = 'tool.exe' }"
            Mock Get-Command { throw 'PATH should not be queried' }

            $result = Resolve-IntuneWinAppUtil -RepositoryRoot $script:repo
            $result.ToolAvailable | Should -BeTrue
            $result.Source | Should -Be 'Configured'
            $result.Path | Should -Be ([System.IO.Path]::GetFullPath($configured))
        }

        It 'returns a finding for an invalid configured path' {
            Set-Content -LiteralPath (Join-Path $script:repo 'Config/settings.psd1') `
                -Value "@{ IntuneWinAppUtilPath = 'missing.exe' }"
            Mock Get-Command { throw 'PATH should not be queried' }

            $result = Resolve-IntuneWinAppUtil -RepositoryRoot $script:repo

            $result.ToolAvailable | Should -BeFalse
            $result.Source | Should -Be 'Configured'
            $result.Findings.Code | Should -Contain 'INTUNEWINAPPUTIL_CONFIG_INVALID'
        }

        It 'returns unavailable when PATH has no result' {
            Mock Get-Command { @() }

            $result = Resolve-IntuneWinAppUtil -RepositoryRoot $script:repo

            $result.ToolAvailable | Should -BeFalse
            $result.Source | Should -Be 'Unavailable'
            $result.Findings.Code | Should -Contain 'INTUNEWINAPPUTIL_UNAVAILABLE'
        }

        It 'accepts exactly one existing PATH result' {
            $pathTool = Join-Path $TestDrive 'path-tool.exe'
            Set-Content -LiteralPath $pathTool -Value 'tool' -NoNewline
            Mock Get-Command { [pscustomobject]@{ Path = $pathTool; Source = $pathTool } }

            $result = Resolve-IntuneWinAppUtil -RepositoryRoot $script:repo

            $result.ToolAvailable | Should -BeTrue
            $result.Source | Should -Be 'PATH'
            $result.Path | Should -Be ([System.IO.Path]::GetFullPath($pathTool))
        }

        It 'refuses multiple PATH results instead of choosing one' {
            $first = Join-Path $TestDrive 'first.exe'
            $second = Join-Path $TestDrive 'second.exe'
            Set-Content -LiteralPath $first -Value 'tool' -NoNewline
            Set-Content -LiteralPath $second -Value 'tool' -NoNewline
            Mock Get-Command {
                @([pscustomobject]@{ Path = $first }, [pscustomobject]@{ Path = $second })
            }

            $result = Resolve-IntuneWinAppUtil -RepositoryRoot $script:repo

            $result.ToolAvailable | Should -BeFalse
            $result.Path | Should -BeNullOrEmpty
            $result.Findings.Code | Should -Contain 'INTUNEWINAPPUTIL_AMBIGUOUS'
        }

        It 'does not download or install tooling' {
            Mock Invoke-WebRequest { throw 'must not download' }
            Mock Install-Module { throw 'must not install' }
            Mock Get-Command { @() }

            { Resolve-IntuneWinAppUtil -RepositoryRoot $script:repo } | Should -Not -Throw
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Install-Module -Times 0 -Exactly
        }
    }

    Describe 'Read-IntuneWinPackageInput' {
        BeforeEach {
            $script:root = Join-Path $TestDrive 'scaffold'
            [void](New-Item -ItemType Directory -Path (Join-Path $script:root 'Package/Files') -Force)
            Set-Content (Join-Path $script:root 'installer.exe') 'installer' -NoNewline
            Set-Content (Join-Path $script:root 'Package/Invoke-AppDeployToolkit.exe') 'exe' -NoNewline
            Set-Content (Join-Path $script:root 'Package/Invoke-AppDeployToolkit.ps1') 'script' -NoNewline
            Copy-Item (Join-Path $script:root 'installer.exe') (Join-Path $script:root 'Package/Files/installer.exe')
            $hash = (Get-FileHash (Join-Path $script:root 'installer.exe')).Hash
            @{ SchemaVersion='1.0'; Readiness='ReviewRequired'; Installer=@{ Path='installer.exe'; FileName='installer.exe'; SHA256=$hash } } |
                ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:root 'PackageManifest.json')
        }
        It 'accepts valid input and returns canonical metadata without writing' {
            $before = @(Get-ChildItem $script:root -Recurse -Force | ForEach-Object FullName)
            $result = Read-IntuneWinPackageInput -OutputPath $script:root
            $result.SourcePath | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:root 'Package')))
            $result.StagedInstallerPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:root 'installer.exe')))
            $result.InstallerPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:root 'Package/Files/installer.exe')))
            $result.InstallerFileName | Should -Be 'installer.exe'
            $result.SHA256 | Should -Match '^[0-9A-F]{64}$'
            @(Get-ChildItem $script:root -Recurse -Force | ForEach-Object FullName) | Should -Be $before
        }
        It 'rejects malformed schema and readiness' {
            Set-Content (Join-Path $script:root 'PackageManifest.json') '{bad'
            { Read-IntuneWinPackageInput $script:root } | Should -Throw '*malformed JSON*'
            @{ SchemaVersion='2.0'; Readiness='ReviewRequired'; Installer=@{} } | ConvertTo-Json | Set-Content (Join-Path $script:root 'PackageManifest.json')
            { Read-IntuneWinPackageInput $script:root } | Should -Throw '*schema*'
            @{ SchemaVersion='1.0'; Readiness='NeedsInput'; Installer=@{} } | ConvertTo-Json | Set-Content (Join-Path $script:root 'PackageManifest.json')
            { Read-IntuneWinPackageInput $script:root } | Should -Throw '*readiness*'
        }
        It 'rejects traversal, hash mismatch, missing files, and occupied output' {
            $hash = (Get-FileHash (Join-Path $script:root 'installer.exe')).Hash
            @{ SchemaVersion='1.0'; Readiness='ReviewRequired'; Installer=@{ Path='../installer.exe'; FileName='../installer.exe'; SHA256=$hash } } | ConvertTo-Json | Set-Content (Join-Path $script:root 'PackageManifest.json')
            { Read-IntuneWinPackageInput $script:root } | Should -Throw '*direct child filename*'
            @{ SchemaVersion='1.0'; Readiness='ReviewRequired'; Installer=@{ Path='nested/installer.exe'; FileName='nested/installer.exe'; SHA256=$hash } } | ConvertTo-Json | Set-Content (Join-Path $script:root 'PackageManifest.json')
            { Read-IntuneWinPackageInput $script:root } | Should -Throw '*direct child filename*'
            @{ SchemaVersion='1.0'; Readiness='ReviewRequired'; Installer=@{ Path='installer.exe'; FileName='installer.exe'; SHA256=('0' * 64) } } | ConvertTo-Json | Set-Content (Join-Path $script:root 'PackageManifest.json')
            { Read-IntuneWinPackageInput $script:root } | Should -Throw '*hash mismatch*'
            Remove-Item (Join-Path $script:root 'Package/Invoke-AppDeployToolkit.exe')
            @{ SchemaVersion='1.0'; Readiness='ReviewRequired'; Installer=@{ Path='installer.exe'; FileName='installer.exe'; SHA256=$hash } } | ConvertTo-Json | Set-Content (Join-Path $script:root 'PackageManifest.json')
            { Read-IntuneWinPackageInput $script:root } | Should -Throw '*PSADT executable*'
            Set-Content (Join-Path $script:root 'Package/Invoke-AppDeployToolkit.exe') 'exe' -NoNewline
            [void](New-Item (Join-Path $script:root 'IntuneWin') -ItemType Directory)
            Set-Content (Join-Path $script:root 'IntuneWin/existing.txt') 'keep'
            { Read-IntuneWinPackageInput $script:root } | Should -Throw '*empty directory*'
            Test-Path (Join-Path $script:root 'IntuneWin/existing.txt') | Should -BeTrue
        }
    }

    Describe 'ConvertTo-IntuneWinBuildScript' {
        It 'renders deterministic portable PS5.1 instructions' {
            $o = [pscustomobject]@{ ManifestPath = 'C:\\work\\PackageManifest.json'; SourcePath = 'C:\\work\\Package'; SetupExecutablePath = 'C:\\work\\Package\\Invoke-AppDeployToolkit.exe'; InstallerPath = 'C:\\work\\Package\\Files\\installer.exe'; InstallerFileName = 'installer.exe'; SHA256 = ('A' * 64); OutputPath = 'C:\\work'; IntuneWinPath = 'C:\\work\\IntuneWin' }
            $a = ConvertTo-IntuneWinBuildScript $o
            ConvertTo-IntuneWinBuildScript $o | Should -Be $a
            $a | Should -Match '\$PSScriptRoot'
            $a | Should -Match '-c.*\$packagePath.*-s.*Invoke-AppDeployToolkit.exe.*-o.*\$outputPath.*-q'
            $a | Should -Match 'stagedInstallerPath'
            $a | Should -Match 'Staged installer'
            $a | Should -Match "\*\.intunewin"
            $a | Should -Match "OrdinalIgnoreCase"
            $a | Should -Match "Length -le 0"
            $a | Should -Match 'Staged installer hash mismatch'
            $a | Should -Not -Match 'C:\\\\work|Invoke-Expression|Invoke-WebRequest|Download|installer\\.exe.*-c'
        }
        It 'parses and rejects incomplete input' {
            { ConvertTo-IntuneWinBuildScript ([pscustomobject]@{ ManifestPath = 'x' }) } | Should -Throw '*missing*SourcePath*'
            $o = [pscustomobject]@{ ManifestPath='x'; SourcePath='x'; SetupExecutablePath='x'; InstallerPath='x'; InstallerFileName='x'; SHA256=('B'*64); OutputPath='x'; IntuneWinPath='x' }
            $t = $null; $e = $null
            [System.Management.Automation.Language.Parser]::ParseInput((ConvertTo-IntuneWinBuildScript $o), [ref]$t, [ref]$e) | Out-Null
            @($e).Count | Should -Be 0
        }
    }

    Describe 'Invoke-IntuneWinAppUtil' {
        It 'passes the exact structured arguments and returns the process exit code' {
            $script:capture = $null
            Mock Start-Process {
                param($FilePath, $ArgumentList, $WorkingDirectory, $Wait, $PassThru)
                $script:capture = [pscustomobject]@{ FilePath=$FilePath; ArgumentList=@($ArgumentList); WorkingDirectory=$WorkingDirectory; Wait=$Wait; PassThru=$PassThru }
                [pscustomobject]@{ ExitCode=17 }
            }
            $code = Invoke-IntuneWinAppUtil -IntuneWinAppUtilPath 'C:\tools\IntuneWinAppUtil.exe' -PackagePath 'C:\scaffold\Package' -OutputPath 'C:\scaffold\IntuneWin'
            $code | Should -Be 17
            $script:capture.FilePath | Should -Be 'C:\tools\IntuneWinAppUtil.exe'
            $script:capture.ArgumentList | Should -Be @('-c', 'C:\scaffold\Package', '-s', 'Invoke-AppDeployToolkit.exe', '-o', 'C:\scaffold\IntuneWin', '-q')
            ($script:capture.WorkingDirectory -replace "\\","/") | Should -Be "C:/scaffold"
            $script:capture.Wait | Should -BeTrue
            $script:capture.PassThru | Should -BeTrue
        }
        It 'does not contain shell interpretation, download, deletion, or validation logic' {
            $source = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'Private/Intune/Invoke-IntuneWinAppUtil.ps1') -Raw
            $source | Should -Not -Match 'Invoke-Expression|Invoke-WebRequest|Start-BitsTransfer|Remove-Item|Get-FileHash|ConvertFrom-Json|Test-Path'
        }
    }

    Describe "New-IntuneWinPackage" {
        BeforeEach {
            $script:intuneRoot = Join-Path $TestDrive ("intune-root-" + [guid]::NewGuid().ToString("N"))
            [void](New-Item -ItemType Directory -Path (Join-Path $script:intuneRoot "Package/Files") -Force)
            Set-Content -LiteralPath (Join-Path $script:intuneRoot "installer.exe") -Value "installer" -NoNewline
            Set-Content -LiteralPath (Join-Path $script:intuneRoot "Package/Invoke-AppDeployToolkit.exe") -Value "exe" -NoNewline
            Set-Content -LiteralPath (Join-Path $script:intuneRoot "Package/Invoke-AppDeployToolkit.ps1") -Value "script" -NoNewline
            Copy-Item -LiteralPath (Join-Path $script:intuneRoot "installer.exe") -Destination (Join-Path $script:intuneRoot "Package/Files/installer.exe")
            $script:intuneHash = (Get-FileHash -LiteralPath (Join-Path $script:intuneRoot "installer.exe")).Hash
            @{ SchemaVersion="1.0"; Readiness="ReviewRequired"; Installer=@{ Path="installer.exe"; FileName="installer.exe"; SHA256=$script:intuneHash } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:intuneRoot "PackageManifest.json")
            $script:intuneTool = Join-Path $TestDrive ("IntuneWinAppUtil-" + [guid]::NewGuid().ToString("N") + ".exe")
            Set-Content -LiteralPath $script:intuneTool -Value "tool" -NoNewline
        }
        It "keeps WhatIf read-only" {
            Mock Resolve-IntuneWinAppUtil { throw "must not resolve" }
            Mock Invoke-IntuneWinAppUtil { throw "must not invoke" }
            $result = New-IntuneWinPackage -OutputPath $script:intuneRoot -WhatIf
            $result.OutputPath | Should -Be (Join-Path $script:intuneRoot "IntuneWin")
            $result.IntuneWinPath | Should -BeNullOrEmpty
            $result.Status | Should -Be "InstructionsOnly"
            $result.ToolAvailable | Should -BeNullOrEmpty
            Test-Path (Join-Path $script:intuneRoot "Build-IntuneWin.ps1") | Should -BeFalse
            Test-Path (Join-Path $script:intuneRoot "IntuneWin") | Should -BeFalse
            Should -Invoke Resolve-IntuneWinAppUtil -Times 0 -Exactly
            Should -Invoke Invoke-IntuneWinAppUtil -Times 0 -Exactly
        }
        It "returns instructions only when tool is unavailable" {
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$false; IntuneWinAppUtilPath=$null; Findings=@([pscustomobject]@{ Code="INTUNEWINAPPUTIL_UNAVAILABLE" }) } }
            Mock Invoke-IntuneWinAppUtil { throw "must not invoke" }
            $result = New-IntuneWinPackage -OutputPath $script:intuneRoot
            $result.OutputPath | Should -Be (Join-Path $script:intuneRoot "IntuneWin")
            $result.IntuneWinPath | Should -BeNullOrEmpty
            $result.Status | Should -Be "InstructionsOnly"
            $result.ToolAvailable | Should -BeFalse
            $result.Findings.Code | Should -Contain "INTUNEWINAPPUTIL_UNAVAILABLE"
            Test-Path $result.BuildInstructionsPath -PathType Leaf | Should -BeTrue
            Should -Invoke Invoke-IntuneWinAppUtil -Times 0 -Exactly
        }
        It "builds and returns the artifact hash and contract" {
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil {
                param($OutputPath)
                [void](New-Item -ItemType Directory -Path $OutputPath -Force)
                Set-Content -LiteralPath (Join-Path $OutputPath "Invoke-AppDeployToolkit.intunewin") -Value "package" -NoNewline
                0
            }
            $result = New-IntuneWinPackage -OutputPath $script:intuneRoot
            $result.Status | Should -Be "Built"
            $result.ToolAvailable | Should -BeTrue
            $result.ToolExitCode | Should -Be 0
            $result.OutputPath | Should -Be (Join-Path $script:intuneRoot "IntuneWin")
            $result.SHA256 | Should -Match "^[0-9A-F]{64}$"
            $result.SourcePath | Should -Be (Join-Path $script:intuneRoot "Package")
            $result.IntuneWinPath | Should -Be (Join-Path $script:intuneRoot "IntuneWin\Invoke-AppDeployToolkit.intunewin")
            Should -Invoke Invoke-IntuneWinAppUtil -Times 1 -Exactly
        }
        It "rejects missing intunewin output" {
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil { 0 }
            { New-IntuneWinPackage -OutputPath $script:intuneRoot } | Should -Throw "*exactly one non-empty*"
        }
        It "rejects empty intunewin output" {
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil { param($OutputPath); [void](New-Item -ItemType Directory -Path $OutputPath -Force); [void](New-Item -ItemType File -Path (Join-Path $OutputPath "Invoke-AppDeployToolkit.intunewin")); 0 }
            { New-IntuneWinPackage -OutputPath $script:intuneRoot } | Should -Throw "*exactly one non-empty*"
        }
        It "rejects wrong-name intunewin output" {
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil { param($OutputPath); [void](New-Item -ItemType Directory -Path $OutputPath -Force); Set-Content -LiteralPath (Join-Path $OutputPath "Other.intunewin") -Value "package" -NoNewline; 0 }
            { New-IntuneWinPackage -OutputPath $script:intuneRoot } | Should -Throw "*exactly one non-empty*"
        }
        It "rejects multiple intunewin outputs" {
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil { param($OutputPath); [void](New-Item -ItemType Directory -Path $OutputPath -Force); Set-Content -LiteralPath (Join-Path $OutputPath "Invoke-AppDeployToolkit.intunewin") -Value "package" -NoNewline; Set-Content -LiteralPath (Join-Path $OutputPath "Other.intunewin") -Value "package" -NoNewline; 0 }
            { New-IntuneWinPackage -OutputPath $script:intuneRoot } | Should -Throw "*exactly one non-empty*"
        }
        It "fails closed on nonzero exit and accepts no artifact" {
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil { 9 }
            { New-IntuneWinPackage -OutputPath $script:intuneRoot } | Should -Throw "*exit code 9*"
        }
    }
}

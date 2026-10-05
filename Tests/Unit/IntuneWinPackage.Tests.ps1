$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

$fixtureScriptPath = Join-Path $PSScriptRoot '..\Fixtures\New-PackageValidationFixture.ps1'

InModuleScope PSPackageForge -Parameters @{ FixtureScriptPath = $fixtureScriptPath } {
    $script:fixtureScriptPath = $FixtureScriptPath
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
        BeforeAll { . $script:fixtureScriptPath }
        BeforeEach {
            $script:fixture = New-PackageValidationFixture -RootPath (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) -CreateReceipt
            $script:root = $script:fixture.ScaffoldRoot
            Copy-Item -LiteralPath $script:fixture.PackagePath -Destination (Join-Path $script:root 'Package') -Recurse
        }
        It 'accepts valid input and returns canonical metadata without writing' {
            $before = @(Get-ChildItem $script:root -Recurse -Force | ForEach-Object FullName)
            $result = Read-IntuneWinPackageInput -OutputPath $script:root
            $result.SourcePath | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:root 'Package')))
            $result.ManifestPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:root 'PackageManifest.json')))
            $result.StagedInstallerPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:root 'setup.exe')))
            $result.SetupExecutablePath | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:root 'Package/Invoke-AppDeployToolkit.exe')))
            $result.SetupScriptPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:root 'Package/Invoke-AppDeployToolkit.ps1')))
            $result.InstallerPath | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:root 'Package/Files/setup.exe')))
            $result.InstallerFileName | Should -Be 'setup.exe'
            $result.SHA256 | Should -Match '^[0-9A-F]{64}$'
            @(Get-ChildItem $script:root -Recurse -Force | ForEach-Object FullName) | Should -Be $before
        }
        It 'rejects unsupported schema and readiness through the manifest reader' {
            $manifestPath = Join-Path $script:root 'PackageManifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $manifest.SchemaVersion = '1.0'
            $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath
            { Read-IntuneWinPackageInput $script:root } | Should -Throw '*schema*'
            $manifest.SchemaVersion = '2.0'; $manifest.Readiness = 'NeedsInput'
            $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath
            { Read-IntuneWinPackageInput $script:root } | Should -Throw '*readiness*'
        }
        It 'rejects shared package tampering before resolving or invoking IntuneWinAppUtil' {
            $cases = Get-PackageValidationMutationMatrix
            foreach ($case in $cases) {
                $fixture = New-PackageValidationFixture -RootPath (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) -CreateReceipt
                $root = $fixture.ScaffoldRoot
                Copy-Item -LiteralPath $fixture.PackagePath -Destination (Join-Path $root 'Package') -Recurse
                & $case.Change $root
                Mock Resolve-IntuneWinAppUtil { throw 'tool resolution must not run' }
                Mock Invoke-IntuneWinAppUtil { throw 'process invocation must not run' }
                { New-IntuneWinPackage -OutputPath $root } | Should -Throw
                Should -Invoke Resolve-IntuneWinAppUtil -Times 0 -Exactly
                Should -Invoke Invoke-IntuneWinAppUtil -Times 0 -Exactly
            }
        }
        It 'rejects a wrong PSADT pin before resolving or invoking IntuneWinAppUtil' {
            $manifestPath = Join-Path $script:root 'PackageManifest.json'
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $manifest.Generator.RequiredPSADTVersion = '4.0.5'
            $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath
            Mock Resolve-IntuneWinAppUtil { throw 'tool resolution must not run' }
            Mock Invoke-IntuneWinAppUtil { throw 'process invocation must not run' }
            { New-IntuneWinPackage -OutputPath $script:root } | Should -Throw '*exactly ''4.0.6''*'
            Should -Invoke Resolve-IntuneWinAppUtil -Times 0 -Exactly
            Should -Invoke Invoke-IntuneWinAppUtil -Times 0 -Exactly
        }
        It 'keeps output occupancy checks action-specific and read-only' {
            [void](New-Item (Join-Path $script:root 'IntuneWin') -ItemType Directory)
            Set-Content (Join-Path $script:root 'IntuneWin/existing.txt') 'keep'
            { Read-IntuneWinPackageInput $script:root } | Should -Throw '*empty directory*'
            Test-Path (Join-Path $script:root 'IntuneWin/existing.txt') | Should -BeTrue
        }
    }

    Describe 'ConvertTo-IntuneWinBuildScript' {
        BeforeAll { . $script:fixtureScriptPath }
        It 'renders deterministic portable PS5.1 instructions' {
            $o = [pscustomobject]@{ ManifestPath = 'C:\\work\\PackageManifest.json'; SourcePath = 'C:\\work\\Package'; SetupExecutablePath = 'C:\\work\\Package\\Invoke-AppDeployToolkit.exe'; InstallerPath = 'C:\\work\\Package\\Files\\installer.exe'; InstallerFileName = 'installer.exe'; SHA256 = ('A' * 64); OutputPath = 'C:\\work'; IntuneWinPath = 'C:\\work\\IntuneWin' }
            $a = ConvertTo-IntuneWinBuildScript $o
            ConvertTo-IntuneWinBuildScript $o | Should -Be $a
            $a | Should -Match '\$PSScriptRoot'
            $a | Should -Match '-c.*\$packagePath.*-s.*Invoke-AppDeployToolkit.exe.*-o.*\$stagePath.*-q'
            $a | Should -Match 'stagedInstaller'
            $a | Should -Match 'Staged installer'
            $a | Should -Match "\*\.intunewin"
            $a | Should -Match "OrdinalIgnoreCase"
            $a | Should -Match "Length -le 0"
            $a | Should -Match 'Staged installer hash mismatch'
            $a | Should -Not -Match 'C:\\\\work|Invoke-Expression|Invoke-WebRequest|Download|installer\\.exe.*-c'
        }
        It 'matches the module validator for every shared package mutation before tool resolution' {
            $scriptSource = ConvertTo-IntuneWinBuildScript ([pscustomobject]@{
                ManifestPath='x'; SourcePath='x'; SetupExecutablePath='x'; InstallerPath='x'
                InstallerFileName='x'; SHA256=('A' * 64); OutputPath='x'; IntuneWinPath='x'
            })
            $tokens = $null; $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($scriptSource, [ref]$tokens, [ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0
            $scriptSource | Should -Not -Match 'Import-Module|Invoke-Expression|Invoke-WebRequest|Download|C:\\work'
            $scriptSource | Should -Match 'Start-Process .* -ArgumentList \$arguments'

            $valid = New-PackageValidationFixture -RootPath (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) -CreateReceipt
            $manifest = Get-Content -LiteralPath $valid.ManifestPath -Raw | ConvertFrom-Json
            $manifest.Generator.Version = '0.2.0'; $manifest.Generator.RequiredPSADTVersion = '4.0.6'
            $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $valid.ManifestPath
            $valid.ManifestInput = Read-PackageForgeManifest -ManifestPath $valid.ManifestPath
            Set-Content -LiteralPath (Join-Path $valid.PackagePath 'PSAppDeployToolkit/PSAppDeployToolkit.psd1') -Value "@{ ModuleVersion = '4.0.6'; RootModule = 'PSAppDeployToolkit.psm1' }" -NoNewline
            Remove-Item -LiteralPath (Join-Path $valid.PackagePath 'PSPackageForgeReceipt.json') -Force
            [void](Write-PackageForgeReceipt -ManifestInput $valid.ManifestInput -PackagePath $valid.PackagePath)
            (Import-PowerShellDataFile -LiteralPath (Join-Path $valid.PackagePath 'PSAppDeployToolkit/PSAppDeployToolkit.psd1')).ModuleVersion | Should -Be '4.0.6'
            Copy-Item -LiteralPath $valid.PackagePath -Destination (Join-Path $valid.ScaffoldRoot 'Package') -Recurse
            $generatedPath = Join-Path $valid.ScaffoldRoot 'Build-IntuneWin.ps1'
            Set-Content -LiteralPath $generatedPath -Value $scriptSource -NoNewline
            $missingTool = Join-Path $TestDrive 'tool-that-does-not-exist.exe'
            try { & $generatedPath -IntuneWinAppUtilPath $missingTool } catch { $validError = $_.Exception.Message }
            $validError | Should -Match 'IntuneWinAppUtilPath was not found'

            foreach ($case in (Get-PackageValidationMutationMatrix)) {
                $fixture = New-PackageValidationFixture -RootPath (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) -CreateReceipt
                $manifest = Get-Content -LiteralPath $fixture.ManifestPath -Raw | ConvertFrom-Json
                $manifest.Generator.Version = '0.2.0'; $manifest.Generator.RequiredPSADTVersion = '4.0.6'
                $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture.ManifestPath
                $fixture.ManifestInput = Read-PackageForgeManifest -ManifestPath $fixture.ManifestPath
                Set-Content -LiteralPath (Join-Path $fixture.PackagePath 'PSAppDeployToolkit/PSAppDeployToolkit.psd1') -Value "@{ ModuleVersion = '4.0.6'; RootModule = 'PSAppDeployToolkit.psm1' }" -NoNewline
                Remove-Item -LiteralPath (Join-Path $fixture.PackagePath 'PSPackageForgeReceipt.json') -Force
                [void](Write-PackageForgeReceipt -ManifestInput $fixture.ManifestInput -PackagePath $fixture.PackagePath)
                Copy-Item -LiteralPath $fixture.PackagePath -Destination (Join-Path $fixture.ScaffoldRoot 'Package') -Recurse
                & $case.Change $fixture.ScaffoldRoot
                { Test-PackageForgePackage -ManifestInput $fixture.ManifestInput -PackagePath (Join-Path $fixture.ScaffoldRoot 'Package') } | Should -Throw
                Set-Content -LiteralPath (Join-Path $fixture.ScaffoldRoot 'Build-IntuneWin.ps1') -Value $scriptSource -NoNewline
                $scriptError = $null
                try { & (Join-Path $fixture.ScaffoldRoot 'Build-IntuneWin.ps1') -IntuneWinAppUtilPath $missingTool } catch { $scriptError = $_.Exception.Message }
                $scriptError | Should -Not -BeNullOrEmpty -Because $case.Name
                $scriptError | Should -Not -Match 'IntuneWinAppUtilPath was not found' -Because "$($case.Name) must fail before tool resolution"
            }
        }
        It 'parses and rejects incomplete input' {
            { ConvertTo-IntuneWinBuildScript ([pscustomobject]@{ ManifestPath = 'x' }) } | Should -Throw '*missing*SourcePath*'
            $o = [pscustomobject]@{ ManifestPath='x'; SourcePath='x'; SetupExecutablePath='x'; InstallerPath='x'; InstallerFileName='x'; SHA256=('B'*64); OutputPath='x'; IntuneWinPath='x' }
            $t = $null; $e = $null
            [System.Management.Automation.Language.Parser]::ParseInput((ConvertTo-IntuneWinBuildScript $o), [ref]$t, [ref]$e) | Out-Null
            @($e).Count | Should -Be 0
        }
    }

    Describe 'Windows command-line argument rendering' {
        It 'renders each argument with Windows quoting rules and joins with one space' {
            ConvertTo-WindowsArgumentString -ArgumentList @('ordinary', 'two words', '') |
                Should -Be 'ordinary "two words" ""'
        }

        It 'preserves embedded quotes and doubles trailing backslashes inside quotes' {
            ConvertTo-WindowsArgumentString -ArgumentList @('say"hello', 'C:\Program Files\', 'C:\Program Files\"') |
                Should -Be '"say\"hello" "C:\Program Files\\" "C:\Program Files\\\""'
        }

        It 'leaves an ordinary trailing backslash unquoted and supports an empty list' {
            ConvertTo-WindowsArgumentString -ArgumentList @('C:\plain\') | Should -Be 'C:\plain\'
            ConvertTo-WindowsArgumentString -ArgumentList @() | Should -Be ''
        }

        It 'renders a command with no arguments without a trailing space' {
            ConvertTo-CommandString -CommandSpec ([CommandSpec]::new('tool.exe', @())) |
                Should -Be 'tool.exe'
        }
    }

    Describe 'Invoke-IntuneWinAppUtil' {
        It 'passes the exact structured arguments and returns the process exit code' {
            $script:capture = $null
            Mock Start-Process {
                param($FilePath, $ArgumentList, $WorkingDirectory, $Wait, $PassThru)
                $script:capture = [pscustomobject]@{ FilePath=$FilePath; ArgumentList=$ArgumentList; WorkingDirectory=$WorkingDirectory; Wait=$Wait; PassThru=$PassThru }
                [pscustomobject]@{ ExitCode=17 }
            }
            $code = Invoke-IntuneWinAppUtil -IntuneWinAppUtilPath 'C:\tools\IntuneWinAppUtil.exe' -PackagePath 'C:\scaffold\Package' -OutputPath 'C:\scaffold\IntuneWin'
            $code | Should -Be 17
            $script:capture.FilePath | Should -Be 'C:\tools\IntuneWinAppUtil.exe'
            $script:capture.ArgumentList | Should -Be '-c C:\scaffold\Package -s Invoke-AppDeployToolkit.exe -o C:\scaffold\IntuneWin -q'
            ($script:capture.WorkingDirectory -replace "\\","/") | Should -Be "C:/scaffold"
            $script:capture.Wait | Should -BeTrue
            $script:capture.PassThru | Should -BeTrue
        }

        It 'passes one pre-rendered argument string with quoted path boundaries' {
            $script:capture = $null
            Mock Start-Process {
                param($ArgumentList)
                $script:capture = $ArgumentList
                [pscustomobject]@{ ExitCode=0 }
            }

            Invoke-IntuneWinAppUtil -IntuneWinAppUtilPath 'C:\tools\IntuneWinAppUtil.exe' -PackagePath 'C:\scaffold root\Package' -OutputPath 'C:\output root\IntuneWin' | Should -Be 0

            $script:capture | Should -Be '-c "C:\scaffold root\Package" -s Invoke-AppDeployToolkit.exe -o "C:\output root\IntuneWin" -q'
        }
        It 'does not contain shell interpretation, download, deletion, or validation logic' {
            $source = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'Private/Intune/Invoke-IntuneWinAppUtil.ps1') -Raw
            $source | Should -Not -Match 'Invoke-Expression|Invoke-WebRequest|Start-BitsTransfer|Remove-Item|Get-FileHash|ConvertFrom-Json|Test-Path'
        }
    }

    Describe "New-IntuneWinPackage" {
        BeforeAll { . $script:fixtureScriptPath }
        BeforeEach {
            $fixture = New-PackageValidationFixture -RootPath (Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))) -CreateReceipt
            $script:intuneRoot = $fixture.ScaffoldRoot
            Copy-Item -LiteralPath $fixture.PackagePath -Destination (Join-Path $script:intuneRoot 'Package') -Recurse
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
            @(Get-ChildItem -LiteralPath $script:intuneRoot -Directory -Filter '.IntuneWin.staging-*').Count | Should -Be 0
            Test-Path (Join-Path $script:intuneRoot 'IntuneWin') | Should -BeFalse
        }
        It "rejects empty intunewin output" {
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil { param($OutputPath); [void](New-Item -ItemType Directory -Path $OutputPath -Force); [void](New-Item -ItemType File -Path (Join-Path $OutputPath "Invoke-AppDeployToolkit.intunewin")); 0 }
            { New-IntuneWinPackage -OutputPath $script:intuneRoot } | Should -Throw "*exactly one non-empty*"
            @(Get-ChildItem -LiteralPath $script:intuneRoot -Directory -Filter '.IntuneWin.staging-*').Count | Should -Be 0
            Test-Path (Join-Path $script:intuneRoot 'IntuneWin') | Should -BeFalse
        }
        It "rejects wrong-name intunewin output" {
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil { param($OutputPath); [void](New-Item -ItemType Directory -Path $OutputPath -Force); Set-Content -LiteralPath (Join-Path $OutputPath "Other.intunewin") -Value "package" -NoNewline; 0 }
            { New-IntuneWinPackage -OutputPath $script:intuneRoot } | Should -Throw "*exactly one non-empty*"
            @(Get-ChildItem -LiteralPath $script:intuneRoot -Directory -Filter '.IntuneWin.staging-*').Count | Should -Be 0
            Test-Path (Join-Path $script:intuneRoot 'IntuneWin') | Should -BeFalse
        }
        It "rejects multiple intunewin outputs" {
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil { param($OutputPath); [void](New-Item -ItemType Directory -Path $OutputPath -Force); Set-Content -LiteralPath (Join-Path $OutputPath "Invoke-AppDeployToolkit.intunewin") -Value "package" -NoNewline; Set-Content -LiteralPath (Join-Path $OutputPath "Other.intunewin") -Value "package" -NoNewline; 0 }
            { New-IntuneWinPackage -OutputPath $script:intuneRoot } | Should -Throw "*exactly one non-empty*"
            @(Get-ChildItem -LiteralPath $script:intuneRoot -Directory -Filter '.IntuneWin.staging-*').Count | Should -Be 0
            Test-Path (Join-Path $script:intuneRoot 'IntuneWin') | Should -BeFalse
        }
        It "fails closed on nonzero exit and accepts no artifact" {
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil { 9 }
            { New-IntuneWinPackage -OutputPath $script:intuneRoot } | Should -Throw "*exit code 9*"
            @(Get-ChildItem -LiteralPath $script:intuneRoot -Directory -Filter '.IntuneWin.staging-*').Count | Should -Be 0
            Test-Path (Join-Path $script:intuneRoot 'IntuneWin') | Should -BeFalse
        }
        It "rejects every extra staging entry and removes only its staging directory" {
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil {
                param($OutputPath)
                Set-Content -LiteralPath (Join-Path $OutputPath "Invoke-AppDeployToolkit.intunewin") -Value "package" -NoNewline
                Set-Content -LiteralPath (Join-Path $OutputPath "extra.txt") -Value "extra" -NoNewline
                0
            }
            { New-IntuneWinPackage -OutputPath $script:intuneRoot } | Should -Throw "*no other output*"
            @(Get-ChildItem -LiteralPath $script:intuneRoot -Directory -Filter '.IntuneWin.staging-*').Count | Should -Be 0
            Test-Path (Join-Path $script:intuneRoot 'IntuneWin') | Should -BeFalse
        }
        It "publishes into an empty destination by same-volume directory rename" {
            [void](New-Item -ItemType Directory -Path (Join-Path $script:intuneRoot 'IntuneWin'))
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil {
                param($OutputPath)
                $OutputPath | Should -Match '\.IntuneWin\.staging-[0-9a-f]+'
                Set-Content -LiteralPath (Join-Path $OutputPath "Invoke-AppDeployToolkit.intunewin") -Value "package" -NoNewline
                0
            }
            $result = New-IntuneWinPackage -OutputPath $script:intuneRoot
            $result.Status | Should -Be 'Built'
            Test-Path -LiteralPath $result.IntuneWinPath -PathType Leaf | Should -BeTrue
        }
        It "restores an empty destination and cleans staging when publish rename fails" {
            $destination = Join-Path $script:intuneRoot 'IntuneWin'
            [void](New-Item -ItemType Directory -Path $destination)
            Mock Resolve-IntuneWinAppUtil { [pscustomobject]@{ ToolAvailable=$true; IntuneWinAppUtilPath=$script:intuneTool; Findings=@() } }
            Mock Invoke-IntuneWinAppUtil {
                param($OutputPath)
                Set-Content -LiteralPath (Join-Path $OutputPath "Invoke-AppDeployToolkit.intunewin") -Value "package" -NoNewline
                0
            }
            Mock Move-Item { throw 'rename failed' }
            { New-IntuneWinPackage -OutputPath $script:intuneRoot } | Should -Throw '*rename failed*'
            Test-Path -LiteralPath $destination -PathType Container | Should -BeTrue
            @(Get-ChildItem -LiteralPath $destination -Force).Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $script:intuneRoot -Directory -Filter '.IntuneWin.staging-*').Count | Should -Be 0
        }
    }
}

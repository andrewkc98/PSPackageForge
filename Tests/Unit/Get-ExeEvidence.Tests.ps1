$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {
    Describe 'Get-ExeEvidence' {
        BeforeAll {
            $script:Root = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Fixtures/framework-stubs'
            function global:Get-ExeRecord { param($r,[string]$f) $r.Evidence | Where-Object Field -eq $f | Select-Object -First 1 }
        }
        AfterAll { Remove-Item function:global:Get-ExeRecord -ErrorAction SilentlyContinue }

        It 'recognizes unique frameworks with exact argument profiles' {
            $expected = @{
                'nsis.exe' = @('Nsis', @('/S'))
                'inno-setup.exe' = @('InnoSetup', @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-'))
                'squirrel.exe' = @('Squirrel', @('--silent'))
                'wix-burn.exe' = @('WiXBurn', @('/quiet','/norestart'))
            }
            foreach ($name in $expected.Keys) {
                $r = Get-ExeEvidence -Path (Join-Path $script:Root $name)
                (Get-ExeRecord $r Framework).Value.ToString() | Should -Be $expected[$name][0]
                (Get-ExeRecord $r InstallCommand).Value.Executable | Should -Be $name
                (Get-ExeRecord $r InstallCommand).Value.ArgumentList | Should -Be $expected[$name][1]
                (Get-ExeRecord $r InstallCommand).Value.ExpectedExitCodes | Should -Be @(0)
                $r.Findings.Code | Should -Contain 'EXE_EXIT_CODES_UNVERIFIED'
            }
        }

        It 'refuses InstallShield arguments' {
            $r = Get-ExeEvidence -Path (Join-Path $script:Root 'installshield.exe')
            (Get-ExeRecord $r Framework).Value.ToString() | Should -Be 'InstallShield'
            (Get-ExeRecord $r InstallCommand) | Should -BeNullOrEmpty
            $r.Findings.Code | Should -Contain 'EXE_ARGUMENT_PROFILE_UNRESOLVED'
        }

        It 'retains fixed candidates and blocks ambiguity' {
            $r = Get-ExeEvidence -Path (Join-Path $script:Root 'ambiguous.exe')
            @((Get-ExeRecord $r FrameworkCandidates).Value | ForEach-Object ToString) | Should -Be @('Nsis','Squirrel')
            (Get-ExeRecord $r Framework) | Should -BeNullOrEmpty
            (Get-ExeRecord $r InstallCommand) | Should -BeNullOrEmpty
            $r.Findings.Code | Should -Contain 'FRAMEWORK_AMBIGUOUS'
        }

        It 'does not guess a framework for unknown EXEs' {
            $r = Get-ExeEvidence -Path (Join-Path $script:Root 'unknown.exe')
            (Get-ExeRecord $r Framework) | Should -BeNullOrEmpty
            (Get-ExeRecord $r FrameworkCandidates).Value | Should -BeNullOrEmpty
            @($r.Findings | ForEach-Object Code) | Should -Contain 'FRAMEWORK_UNRESOLVED'
        }

        It 'emits fixed container facts and no forbidden inference' {
            $r = Get-ExeEvidence -Path (Join-Path $script:Root 'nsis.exe')
            (Get-ExeRecord $r ContainerType).Value | Should -Be 'Exe'
            (Get-ExeRecord $r PayloadType).Value | Should -Be 'Exe'
            (Get-ExeRecord $r MsiKind).Value | Should -Be 'NotApplicable'
            @($r.Evidence | Where-Object Field -eq InstallCommand | ForEach-Object { $_.Value.ArgumentList }) | Should -Not -Contain '/allusers'
            @($r.Evidence | Where-Object Field -eq InstallCommand | ForEach-Object { $_.Value.ArgumentList }) | Should -Not -Contain '/uninstall'
        }

        It 'uses inferred provenance for commands and omits unknown architecture' {
            $command = Get-ExeRecord (Get-ExeEvidence -Path (Join-Path $script:Root 'nsis.exe')) InstallCommand
            $command.Source | Should -Be ([EvidenceSource]::Inferred)
            $bytes = [IO.File]::ReadAllBytes((Join-Path $script:Root 'unknown.exe'))
            $offset = [BitConverter]::ToInt32($bytes, 0x3C)
            $bytes[$offset + 4] = 0xFF; $bytes[$offset + 5] = 0xFF
            $path = Join-Path $TestDrive 'unknown-machine.exe'; [IO.File]::WriteAllBytes($path, $bytes)
            (Get-ExeRecord (Get-ExeEvidence -Path $path) InstallerArchitecture) | Should -BeNullOrEmpty
        }
    }
}

<# Optional read-only regressions for vendor installers supplied locally by a Windows test operator. #>

$script:ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:ModuleRoot 'PSPackageForge.psd1') -Force

Describe 'Optional live EXE regressions' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeAll {
        $script:ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:InstallersPath = Join-Path $script:ModuleRoot 'Installers'
    }

    It 'reads a KiCad installer without executing it' {
        $files = if (Test-Path -LiteralPath $script:InstallersPath -PathType Container) {
            @(Get-ChildItem -LiteralPath $script:InstallersPath -File -Recurse | Where-Object {
                $_.Extension -ieq '.exe' -and $_.BaseName -match '(?i)kicad'
            })
        }
        else { @() }
        if (@($files).Count -eq 0) {
            Set-ItResult -Skipped -Because "No KiCad .exe was found under the repository Installers directory."
            return
        }
        $info = Get-InstallerInfo -Path @($files)[0].FullName
        $info.ContainerType | Should -Be 'Exe'
        $info.Framework | Should -Be 'Nsis'
        $info.GetEvidence('InstallCommand').Value.ArgumentList | Should -Be @('/S')
    }

    It 'reads an Obsidian installer without executing it' {
        $files = if (Test-Path -LiteralPath $script:InstallersPath -PathType Container) {
            @(Get-ChildItem -LiteralPath $script:InstallersPath -File -Recurse | Where-Object {
                $_.Extension -ieq '.exe' -and $_.BaseName -match '(?i)obsidian'
            })
        }
        else { @() }
        if (@($files).Count -eq 0) {
            Set-ItResult -Skipped -Because "No Obsidian .exe was found under the repository Installers directory."
            return
        }
        $info = Get-InstallerInfo -Path @($files)[0].FullName
        $info.ContainerType | Should -Be 'Exe'
        $info.Framework | Should -Be 'Squirrel'
        $info.GetEvidence('InstallCommand').Value.ArgumentList | Should -Be @('--silent')
    }
}

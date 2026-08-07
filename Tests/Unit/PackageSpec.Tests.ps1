<#
    Build-order steps 6 and 7: deployment resolution and the single command-render boundary.
#>

$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force

InModuleScope PSPackageForge {

    BeforeAll {
        $script:FixturePath = Join-Path $ModuleRoot 'Tests\Fixtures\native-clean.msi'
    }

    Describe 'Resolve-PackageSpec' {

        It 'builds standard native-MSI commands without using the MSI filename for uninstall' {
            $context = [EvidenceRecord]::new(
                'SelectedContext', 'System', [EvidenceSource]::UserOverride, [ConfidenceLevel]::High)
            $info = Get-InstallerInfo -Path $script:FixturePath -AdditionalEvidence $context

            $spec = Resolve-PackageSpec -InstallerInfo $info

            $spec.InstallCommand.Executable    | Should -Be 'msiexec.exe'
            $spec.InstallCommand.ArgumentList  | Should -Be @('/i', 'native-clean.msi', '/qn')
            $spec.UninstallCommand.ArgumentList | Should -Be @('/x', $info.ProductCode, '/qn')
            $spec.UninstallCommand.ArgumentList | Should -Not -Contain 'native-clean.msi'
        }

        It 'produces ReviewRequired only when all four critical decisions resolve' {
            $context = [EvidenceRecord]::new(
                'SelectedContext', 'System', [EvidenceSource]::UserOverride, [ConfidenceLevel]::High)
            $info = Get-InstallerInfo -Path $script:FixturePath -AdditionalEvidence $context

            $spec = Resolve-PackageSpec -InstallerInfo $info

            $spec.Readiness             | Should -Be ([ReadinessLevel]::ReviewRequired)
            $spec.BlockingFindings      | Should -BeNullOrEmpty
            $spec.DetectionSpec.Count   | Should -Be 1
            $spec.DetectionSpec[0].Kind | Should -Be ([DetectionKind]::File)
            $spec.DetectionSpec[0].Operator | Should -Be ([DetectionOperator]::Exists)
        }

        It 'blocks when install context is unresolved' {
            $info = Get-InstallerInfo -Path $script:FixturePath
            $info.Evidence         = @($info.Evidence | Where-Object Field -ne 'SelectedContext')
            $info.ResolvedEvidence = @($info.ResolvedEvidence | Where-Object Field -ne 'SelectedContext')
            $spec = Resolve-PackageSpec -InstallerInfo $info

            $spec.Readiness | Should -Be ([ReadinessLevel]::NeedsInput)
            ($spec.BlockingFindings | Where-Object Code -eq 'INSTALL_CONTEXT_UNRESOLVED') |
                Should -Not -BeNullOrEmpty
        }

        It 'records provenance for every resolved deployment decision' {
            $context = [EvidenceRecord]::new(
                'SelectedContext', 'System', [EvidenceSource]::UserOverride, [ConfidenceLevel]::High)
            $info = Get-InstallerInfo -Path $script:FixturePath -AdditionalEvidence $context
            $spec = Resolve-PackageSpec -InstallerInfo $info

            $spec.DecisionEvidence.Field | Should -Contain 'InstallCommand'
            $spec.DecisionEvidence.Field | Should -Contain 'UninstallCommand'
            $spec.DecisionEvidence.Field | Should -Contain 'SelectedContext'
            $spec.DecisionEvidence.Field | Should -Contain 'Detection'
        }

        It 'blocks a Low-confidence detection decision' {
            $additional = @(
                [EvidenceRecord]::new('SelectedContext', 'System', [EvidenceSource]::UserOverride, [ConfidenceLevel]::High)
                [EvidenceRecord]::new('DetectionTarget', 'C:\Reviewed\app.exe', [EvidenceSource]::UserOverride, [ConfidenceLevel]::Low)
            )
            $info = Get-InstallerInfo -Path $script:FixturePath -AdditionalEvidence $additional
            $spec = Resolve-PackageSpec -InstallerInfo $info

            $spec.Readiness | Should -Be ([ReadinessLevel]::NeedsInput)
            ($spec.BlockingFindings | Where-Object Code -eq 'DETECTION_LOW_CONFIDENCE') |
                Should -Not -BeNullOrEmpty
        }

        It 'includes the modeled default return codes without treating 1619 as success' {
            $codes = Get-DefaultReturnCodeMap

            $codes.Code | Should -Contain 0
            $codes.Code | Should -Contain 3010
            $codes.Code | Should -Contain 1641
            $codes.Code | Should -Contain 1618
            $codes.Code | Should -Contain 1707
            $codes.Code | Should -Not -Contain 1619
        }

        It 'never generates an msiexec uninstall for a wrapper MSI' {
            $info = [InstallerInfo]::new()
            $info.Path                 = 'C:\Source\wrapper.msi'
            $info.FileName             = 'wrapper.msi'
            $info.ContainerType        = [ContainerType]::Msi
            $info.PayloadType          = [PayloadType]::Exe
            $info.MsiKind              = [MsiKind]::Wrapper
            $info.ProductCode          = '{33333333-3333-3333-3333-333333333333}'
            $info.ProductCodePresent   = $true
            $info.SupportsMsiUninstall = $false
            $info.Evidence = @(
                [EvidenceRecord]::new('SelectedContext', 'System', [EvidenceSource]::UserOverride, [ConfidenceLevel]::High)
            )
            $info.ResolvedEvidence = @($info.Evidence)

            $spec = Resolve-PackageSpec -InstallerInfo $info

            $spec.InstallCommand.IsResolved()   | Should -BeTrue
            $spec.UninstallCommand.IsResolved() | Should -BeFalse
            ($spec.BlockingFindings | Where-Object Code -eq 'UNINSTALL_COMMAND_UNRESOLVED') |
                Should -Not -BeNullOrEmpty
        }
    }

    Describe 'ConvertTo-CommandString' {

        It 'quotes only the argument that needs quoting' {
            $command = [CommandSpec]::new('msiexec.exe', @('/i', 'App Name.msi', '/qn'))

            ConvertTo-CommandString -CommandSpec $command |
                Should -Be 'msiexec.exe /i "App Name.msi" /qn'
        }

        It 'quotes an executable path containing spaces' {
            $command = [CommandSpec]::new('C:\Program Files\Vendor\setup.exe', @('/S'))

            ConvertTo-CommandString -CommandSpec $command |
                Should -Be '"C:\Program Files\Vendor\setup.exe" /S'
        }

        It 'preserves empty arguments explicitly' {
            $command = [CommandSpec]::new('tool.exe', @(''))

            ConvertTo-CommandString -CommandSpec $command | Should -Be 'tool.exe ""'
        }

        It 'escapes embedded quotes using Windows command-line rules' {
            $command = [CommandSpec]::new('tool.exe', @('say"hello'))

            ConvertTo-CommandString -CommandSpec $command | Should -Be 'tool.exe "say\"hello"'
        }

        It 'refuses to render an unresolved command' {
            { ConvertTo-CommandString -CommandSpec ([CommandSpec]::new()) } |
                Should -Throw '*unresolved*'
        }
    }
}

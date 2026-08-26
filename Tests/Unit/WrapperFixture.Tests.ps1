<#
    Build order step 9: end-to-end coverage for the committed wrapper-style.msi fixture
    (Tests\Fixtures\wrapper-style.msi, built by Tests\Fixtures\New-WrapperFixture.ps1).

    Get-MsiEvidence.Tests.ps1 already covers wrapper CLASSIFICATION RULES against
    synthetic MsiDatabase shapes -- that is deliberate, so the rules do not depend on a
    committed binary. This file instead proves the real COM read path and the honest
    refusal it feeds into actually hold end to end, against the real fixture file, the
    same way Get-MsiEvidence.Tests.ps1's "against the committed native fixture" Describe
    does for native-clean.msi:

      * Get-InstallerInfo through the public boundary.
      * Container detection trusts the fixture's real OLE2 bytes, not just its extension.
      * Resolve-PackageSpec's honest refusal -- UNINSTALL_COMMAND_UNRESOLVED and
        DETECTION_UNRESOLVED stay Blocking, Readiness stays NeedsInput, and nothing about
        the wrapper shape is silently forgiven.
      * The fixture's identity does not accidentally match Config\known-quirks.psd1's
        Firefox ESR entry -- if it did, the quirk would fill in InstallLocation /
        DetectionTarget / UninstallCommand and this suite would stop testing the honest
        refusal it exists to test.
#>

$ModuleRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $ModuleRoot 'PSPackageForge.psd1') -Force


Describe 'Get-InstallerInfo public boundary against wrapper-style.msi' `
    -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {

    BeforeAll {
        # Recomputed here rather than relying on a bare top-of-file variable: Pester runs
        # BeforeAll/It blocks in a later phase than the container script's own top-level
        # statements, so only $script:-scoped values set from inside a block are reliably
        # visible (the same pattern Tests\Integration\Get-InstallerInfo.Tests.ps1 uses).
        $script:ModuleRoot  = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:FixturePath = Join-Path $script:ModuleRoot 'Tests\Fixtures\wrapper-style.msi'
        $script:Result      = Get-InstallerInfo -Path $script:FixturePath
    }

    It 'returns an InstallerInfo instance' {
        $script:Result.GetType().Name | Should -Be 'InstallerInfo'
    }

    It 'classifies the fixture as a wrapper MSI with an EXE payload' {
        $script:Result.ContainerType        | Should -Be 'Msi'
        $script:Result.MsiKind              | Should -Be 'Wrapper'
        $script:Result.PayloadType          | Should -Be 'Exe'
        $script:Result.SupportsMsiUninstall | Should -BeFalse
    }

    It 'reports a ProductCode present even though msiexec cannot uninstall the product' {
        # The whole Firefox-shaped regression in one assertion: a ProductCode existing
        # syntactically does not mean 'msiexec /x' will remove anything.
        $script:Result.ProductCodePresent | Should -BeTrue
        $script:Result.ProductCode        | Should -Not -BeNullOrEmpty
    }

    It 'raises MSI_WRAPPER_DETECTED as a Warning' {
        $finding = $script:Result.Findings | Where-Object Code -eq 'MSI_WRAPPER_DETECTED'

        $finding           | Should -Not -BeNullOrEmpty
        $finding.Severity  | Should -Be 'Warning'
    }

    It 'raises MSI_PAYLOAD_NOT_INTROSPECTABLE as Info, explaining the refusal' {
        $finding = $script:Result.Findings | Where-Object Code -eq 'MSI_PAYLOAD_NOT_INTROSPECTABLE'

        $finding           | Should -Not -BeNullOrEmpty
        $finding.Severity  | Should -Be 'Info'
        $finding.Field     | Should -Be 'InstallLocation'
    }

    It 'derives no InstallLocation or DetectionTarget from the wrapper Directory chain' {
        <#
            The fixture's Directory table has a TARGETDIR row, so a naive walk would not
            even dead-end cleanly -- it is the absent File table that forces MsiKind to
            Wrapper in the first place (Get-MsiEvidence.ps1), and Wrapper is what
            suppresses install-location resolution entirely, regardless of what the
            Directory table contains.
        #>
        $script:Result.GetResolvedEvidence('InstallLocation') | Should -BeNullOrEmpty
        $script:Result.GetResolvedEvidence('DetectionTarget') | Should -BeNullOrEmpty
    }

    It 'does not leave the fixture locked after the public command returns' {
        { [System.IO.File]::Open($script:FixturePath, 'Open', 'Read', 'None').Dispose() } |
            Should -Not -Throw
    }
}


Describe 'Container detection against wrapper-style.msi' {

    BeforeAll {
        $script:ModuleRoot  = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:FixturePath = Join-Path $script:ModuleRoot 'Tests\Fixtures\wrapper-style.msi'
    }

    It 'reads the fixture as an OLE2 compound document with no extension mismatch' {
        InModuleScope PSPackageForge -Parameters @{ FixturePath = $script:FixturePath } {
            param($FixturePath)

            $detection = Get-InstallerContainerType -Path $FixturePath

            $detection.ByContent     | Should -Be ([ContainerType]::Msi)
            $detection.ByExtension   | Should -Be ([ContainerType]::Msi)
            $detection.ContainerType | Should -Be ([ContainerType]::Msi)
            $detection.Mismatch      | Should -BeFalse
            $detection.HeaderHex     | Should -BeLike 'D0CF11E0A1B11AE1*'
        }
    }
}


InModuleScope PSPackageForge {

    Describe 'Resolve-PackageSpec against wrapper-style.msi: the honest refusal end to end' `
        -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {

        BeforeAll {
            $script:FixturePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Fixtures\wrapper-style.msi'

            <#
                ALLUSERS=1 in the fixture's Property table resolves SelectedContext to
                System at Medium confidence on its own (Get-MsiEvidence.ps1), so no
                AdditionalEvidence is needed here to keep that one decision from adding
                collateral blocking findings -- what is under test is the uninstall
                command and detection, not context.
            #>
            $script:Info = Get-InstallerInfo -Path $script:FixturePath
            $script:Spec = Resolve-PackageSpec -InstallerInfo $script:Info
        }

        It 'never resolves an uninstall command for a wrapper MSI' {
            $script:Spec.UninstallCommand.IsResolved() | Should -BeFalse

            $finding = $script:Spec.BlockingFindings | Where-Object Code -eq 'UNINSTALL_COMMAND_UNRESOLVED'
            $finding             | Should -Not -BeNullOrEmpty
            $finding.Severity    | Should -Be ([FindingSeverity]::Blocking)
        }

        It 'never resolves a detection rule for a wrapper MSI with no ProductCode-based fallback available' {
            # SupportsMsiUninstall is $false, so Resolve-DetectionSpec's MsiProductCode
            # fallback (Private\Resolution\Resolve-DetectionSpec.ps1) is also refused.
            $script:Spec.DetectionSpec | Should -BeNullOrEmpty

            $finding = $script:Spec.BlockingFindings | Where-Object Code -eq 'DETECTION_UNRESOLVED'
            $finding             | Should -Not -BeNullOrEmpty
            $finding.Severity    | Should -Be ([FindingSeverity]::Blocking)
        }

        It 'still resolves a standard msiexec install command, since installing a wrapper is unambiguous' {
            # Only uninstall/detection are refused: msiexec /i <file> /qn always runs the
            # embedded custom action regardless of what it turns out to wrap.
            $script:Spec.InstallCommand.IsResolved() | Should -BeTrue
            $script:Spec.InstallCommand.Executable   | Should -Be 'msiexec.exe'
        }

        It 'caps Readiness at NeedsInput rather than ReviewRequired' {
            $script:Spec.Readiness | Should -Be ([ReadinessLevel]::NeedsInput)
        }
    }


    Describe 'wrapper-style.msi classifies as Wrapper on its own shape, matching no known quirk' `
        -Skip:($PSVersionTable.PSEdition -ne 'Desktop' -and $env:OS -ne 'Windows_NT') {

        <#
            Config\known-quirks.psd1 (build order step 9, a concurrently developed file)
            carries a single entry keyed on Firefox ESR's real UpgradeCode. This fixture's
            identity constants are pinned in New-WrapperFixture.ps1 specifically to be
            unrelated to that entry's Match criteria, so MsiKind = Wrapper here has to come
            from the MSI shape alone (empty File table + a type-3074 custom action) -- not
            from a quirk filling in an answer Get-MsiEvidence itself declined to give.
        #>

        BeforeAll {
            $script:FixturePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'Fixtures\wrapper-style.msi'
            $script:Info        = Get-InstallerInfo -Path $script:FixturePath
        }

        It 'does not match the Firefox ESR quirk identity' {
            $script:Info.ProductName | Should -Not -BeLike '*Firefox*'
            $script:Info.Manufacturer | Should -Not -Be 'Mozilla'
            $script:Info.UpgradeCode | Should -Not -Be '{3118AB4C-B433-4FBB-B9FA-8F9CA4B5C103}'
        }

        It 'applies no known quirk to this installer' {
            ($script:Info.Findings | Where-Object Code -eq 'KNOWN_QUIRK_APPLIED') | Should -BeNullOrEmpty
            ($script:Info.Evidence | Where-Object Source -eq ([EvidenceSource]::KnownQuirk)) | Should -BeNullOrEmpty
        }

        It 'still classifies Wrapper purely from the MSI table shape' {
            $script:Info.MsiKind | Should -Be ([MsiKind]::Wrapper)

            $reason = ($script:Info.Evidence | Where-Object Field -eq 'MsiKind').Notes
            $reason | Should -BeLike '*no File payload*'
        }
    }
}

<#
    Live regression coverage for the Firefox ESR wrapper quirk (build order step 9).

    This is the case the known-quirk system exists for: Get-MsiEvidence deliberately
    refuses to report an InstallLocation or DetectionTarget for a wrapper MSI (plan §8.1),
    and Config\known-quirks.psd1's firefox-esr-msi-wrapper entry is what fills that
    refusal with a reviewed, honestly attributed answer.

    Guarded so CI, which never downloads vendor installers (plan §11), skips cleanly when
    the real Firefox ESR MSI is not present locally. The filter is a wildcard on purpose --
    'Firefox Setup *esr.msi' -- so a version bump to the committed installer does not quietly
    disable this regression the way pinning the exact filename would.
#>

<#
    -Skip is evaluated once, during Pester's discovery pass, so the presence check has to
    happen here at file (discovery) scope. Pester's run phase re-invokes only the
    BeforeAll/It bodies afterwards -- top-level variables set outside them do not carry
    over -- so BeforeAll below recomputes the paths it needs rather than reusing these.
#>
$script:DiscoveryModuleRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:DiscoveryInstallerPath = Get-ChildItem -Path (Join-Path $script:DiscoveryModuleRoot 'Installers') -Filter 'Firefox Setup *esr.msi' -File -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
$script:HasFirefoxInstaller = -not [string]::IsNullOrWhiteSpace($script:DiscoveryInstallerPath)

Describe 'Known quirk: Firefox ESR MSI wrapper' -Skip:(-not $script:HasFirefoxInstaller) {

    BeforeAll {
        $script:ModuleRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:ManifestPath  = Join-Path $script:ModuleRoot 'PSPackageForge.psd1'
        $script:InstallerPath = Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Installers') -Filter 'Firefox Setup *esr.msi' -File |
            Select-Object -First 1 -ExpandProperty FullName

        Import-Module $script:ManifestPath -Force
        $script:Result = Get-InstallerInfo -Path $script:InstallerPath
    }

    It 'still classifies the container and wrapper shape from the MSI itself, unaffected by the quirk' {
        $script:Result.ContainerType        | Should -Be 'Msi'
        $script:Result.MsiKind              | Should -Be 'Wrapper'
        $script:Result.SupportsMsiUninstall | Should -BeFalse

        ($script:Result.Findings | Where-Object Code -eq 'MSI_WRAPPER_DETECTED') | Should -Not -BeNullOrEmpty
    }

    It 'fills InstallLocation and DetectionTarget from the quirk, exactly where the MSI provider refused' {
        # This is the whole point: MSI_PAYLOAD_NOT_INTROSPECTABLE is the refusal, and the
        # quirk is what supplies an honestly attributed answer instead.
        ($script:Result.Findings | Where-Object Code -eq 'MSI_PAYLOAD_NOT_INTROSPECTABLE') | Should -Not -BeNullOrEmpty

        $installLocation = $script:Result.GetResolvedEvidence('InstallLocation')
        $detectionTarget = $script:Result.GetResolvedEvidence('DetectionTarget')

        $installLocation          | Should -Not -BeNullOrEmpty
        $installLocation.Source   | Should -Be 'KnownQuirk'
        $installLocation.Value    | Should -Be '%ProgramFiles%\Mozilla Firefox'

        $detectionTarget          | Should -Not -BeNullOrEmpty
        $detectionTarget.Source   | Should -Be 'KnownQuirk'
        $detectionTarget.Value    | Should -Be '%ProgramFiles%\Mozilla Firefox\firefox.exe'
    }

    It 'applies the quirk without contradicting anything the MSI itself reported' {
        # Nothing should have resolved silently or by surprise: the quirk only fills gaps,
        # so there must be no EVIDENCE_CONFLICT anywhere in this run.
        ($script:Result.Findings | Where-Object Code -eq 'EVIDENCE_CONFLICT') | Should -BeNullOrEmpty
        ($script:Result.Findings | Where-Object Code -eq 'KNOWN_QUIRK_APPLIED') | Should -Not -BeNullOrEmpty
        ($script:Result.Findings | Where-Object Code -eq 'KNOWN_QUIRK_CONFIG_INVALID') | Should -BeNullOrEmpty
    }

    Context 'Resolve-PackageSpec' {

        BeforeAll {
            # Resolve-PackageSpec is a Private function; run it inside the module's own
            # session state rather than importing InModuleScope machinery into an
            # otherwise public-boundary integration file (same idiom as
            # Tests\Integration\New-PackageScaffold.Tests.ps1's use of & (Get-Module ...)).
            $script:Spec = & (Get-Module PSPackageForge) {
                param($Info)
                Resolve-PackageSpec -InstallerInfo $Info
            } $script:Result
        }

        It 'converts the quirk''s hashtable UninstallCommand into the vendor helper.exe /S command' {
            # The wrapper MSI has no ProductCode msiexec can remove, so the fallback in
            # Resolve-PackageSpec (UNINSTALL_COMMAND_UNRESOLVED) must not have fired -- the
            # quirk's hashtable evidence had to convert successfully instead.
            $script:Spec.UninstallCommand.Executable        | Should -Be '%ProgramFiles%\Mozilla Firefox\uninstall\helper.exe'
            $script:Spec.UninstallCommand.ArgumentList      | Should -Be @('/S')
            $script:Spec.UninstallCommand.ExpectedExitCodes | Should -Be @(0)
        }

        It 'still resolves InstallCommand to the standard MSI-quiet fallback' {
            # No quirk evidence supplies InstallCommand -- msiexec /i genuinely does drive
            # the wrapper's embedded custom actions, unlike msiexec /x on the way out.
            $script:Spec.InstallCommand.Executable | Should -Be 'msiexec.exe'
        }

        It 'selects System context and File-existence detection from the quirk-supplied evidence' {
            $script:Spec.SelectedContext                | Should -Be 'System'
            $script:Spec.DetectionSpec.Count             | Should -Be 1
            $script:Spec.DetectionSpec[0].Kind            | Should -Be 'File'
            $script:Spec.DetectionSpec[0].Path            | Should -Be '%ProgramFiles%\Mozilla Firefox'
            $script:Spec.DetectionSpec[0].FileName         | Should -Be 'firefox.exe'
        }

        It 'reaches ReviewRequired with nothing left silently unresolved' {
            # All four critical decisions (install, uninstall, context, detection) resolve
            # from real evidence -- vendor MSI facts plus the reviewed quirk -- so nothing
            # should be blocking, and the readiness ceiling for this scaffolder should be
            # reached rather than falling back to NeedsInput.
            $script:Spec.BlockingFindings | Should -BeNullOrEmpty
            $script:Spec.Readiness        | Should -Be 'ReviewRequired'
        }
    }
}

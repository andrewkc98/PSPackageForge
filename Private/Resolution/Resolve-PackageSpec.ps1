function Get-DefaultReturnCodeMap {
    [CmdletBinding()]
    [OutputType([ReturnCodeMapping])]
    param()

    [ReturnCodeMapping]::new(0,    'Success',                     [ReturnCodeClass]::Success)
    [ReturnCodeMapping]::new(3010, 'Soft reboot required',        [ReturnCodeClass]::SuccessRebootRequired)
    [ReturnCodeMapping]::new(1641, 'Reboot initiated',            [ReturnCodeClass]::SuccessRebootInitiated)
    [ReturnCodeMapping]::new(1618, 'Another installation active', [ReturnCodeClass]::Retry)
    [ReturnCodeMapping]::new(1707, 'Installation completed',      [ReturnCodeClass]::Success)
}


function Resolve-PackageSpec {
    <#
        .SYNOPSIS
            Resolves deployment decisions from an InstallerInfo without changing facts.
    #>
    [CmdletBinding()]
    [OutputType([PackageSpec])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [InstallerInfo] $InstallerInfo,

        [DetectionOperator] $DetectionOperator = [DetectionOperator]::Exact
    )

    process {
        $spec             = [PackageSpec]::new()
        $decisionEvidence = [System.Collections.Generic.List[EvidenceRecord]]::new()
        $blocking         = [System.Collections.Generic.List[Finding]]::new()

        $spec.SchemaVersion   = $script:ManifestSchemaVersion
        $spec.GeneratorVersion = "$script:GeneratorVersion"
        $spec.ReturnCodeMap   = Get-DefaultReturnCodeMap
        $spec.RebootBehavior  = [RebootBehaviorType]::NoAction

        foreach ($finding in $InstallerInfo.Findings) {
            if ($finding.IsBlocking()) { $blocking.Add($finding) }
        }

        # Explicit structured command evidence wins. Strings are never reparsed.
        $installRecord = $InstallerInfo.GetResolvedEvidence('InstallCommand')
        if ($null -ne $installRecord -and $installRecord.Value -is [CommandSpec]) {
            $spec.InstallCommand = $installRecord.Value
            $decisionEvidence.Add($installRecord.Clone())
        }
        elseif ($InstallerInfo.ContainerType -eq [ContainerType]::Msi) {
            $spec.InstallCommand = [CommandSpec]::new(
                'msiexec.exe', @('/i', $InstallerInfo.FileName, '/qn'), @(0, 3010, 1641, 1707))
            $decisionEvidence.Add([EvidenceRecord]::new(
                'InstallCommand', $spec.InstallCommand.ToOrderedDictionary(), [EvidenceSource]::MsiDatabase,
                [ConfidenceLevel]::High, 'Standard MSI quiet-install command from the supplied MSI filename.'))
        }
        else {
            $blocking.Add((New-ForgeFinding -Severity Blocking -Code 'INSTALL_COMMAND_UNRESOLVED' -Field 'InstallCommand' -Message (
                'No structured install command can be resolved from the available evidence.')))
        }

        $uninstallRecord = $InstallerInfo.GetResolvedEvidence('UninstallCommand')
        if ($null -ne $uninstallRecord -and $uninstallRecord.Value -is [CommandSpec]) {
            $spec.UninstallCommand = $uninstallRecord.Value
            $decisionEvidence.Add($uninstallRecord.Clone())
        }
        elseif ($InstallerInfo.MsiKind -eq [MsiKind]::Native -and
                $InstallerInfo.SupportsMsiUninstall -and
                -not [string]::IsNullOrWhiteSpace($InstallerInfo.ProductCode)) {
            $spec.UninstallCommand = [CommandSpec]::new(
                'msiexec.exe', @('/x', $InstallerInfo.ProductCode, '/qn'), @(0, 3010, 1641, 1707))
            $decisionEvidence.Add([EvidenceRecord]::new(
                'UninstallCommand', $spec.UninstallCommand.ToOrderedDictionary(), [EvidenceSource]::MsiDatabase,
                [ConfidenceLevel]::High, 'Native MSI uninstall uses ProductCode, never the source MSI filename.'))
        }
        else {
            $blocking.Add((New-ForgeFinding -Severity Blocking -Code 'UNINSTALL_COMMAND_UNRESOLVED' -Field 'UninstallCommand' -Message (
                'No trustworthy uninstall command is available. Wrapper MSIs require the vendor uninstaller or reviewed discovery evidence.')))
        }

        $contextRecord       = $InstallerInfo.GetResolvedEvidence('SelectedContext')
        $spec.ContextEvidence = $InstallerInfo.GetRawEvidence('SelectedContext')
        if ($null -ne $contextRecord) {
            $spec.SelectedContext = Get-ForgeEnumValue -Value $contextRecord.Value -Type ([InstallContext]) -Default ([InstallContext]::Unknown)
            if ($spec.SelectedContext -ne [InstallContext]::Unknown) {
                $spec.SupportedContexts = @($spec.SelectedContext)
                $spec.RequiresLogonWhenUserContext = $spec.SelectedContext -eq [InstallContext]::User
                $decisionEvidence.Add($contextRecord.Clone())
            }
        }

        if ($spec.SelectedContext -eq [InstallContext]::Unknown) {
            $blocking.Add((New-ForgeFinding -Severity Blocking -Code 'INSTALL_CONTEXT_UNRESOLVED' -Field 'SelectedContext' -Message (
                'Install context cannot be selected from the available evidence. Supply reviewed machine/user context evidence.')))
        }
        elseif ($contextRecord.Confidence -eq [ConfidenceLevel]::Low) {
            $blocking.Add((New-ForgeFinding -Severity Blocking -Code 'INSTALL_CONTEXT_LOW_CONFIDENCE' -Field 'SelectedContext' -Message (
                'The selected install context is only Low confidence and cannot produce runnable output.')))
        }

        $detection = Resolve-DetectionSpec -InstallerInfo $InstallerInfo -VersionOperator $DetectionOperator
        if ($null -ne $detection) {
            $spec.DetectionSpec = @($detection)
            $detectionSource = $InstallerInfo.GetResolvedEvidence('DetectionTarget')
            if ($null -eq $detectionSource) { $detectionSource = $InstallerInfo.GetResolvedEvidence('ProductCode') }
            $source = if ($null -ne $detectionSource) { $detectionSource.Source } else { [EvidenceSource]::Inferred }
            $decisionEvidence.Add([EvidenceRecord]::new(
                'Detection', $detection.ToOrderedDictionary(), $source, $detection.Confidence, $detection.Rationale))

            if ($detection.Confidence -eq [ConfidenceLevel]::Low) {
                $blocking.Add((New-ForgeFinding -Severity Blocking -Code 'DETECTION_LOW_CONFIDENCE' -Field 'Detection' -Message (
                    'The resolved detection method is only Low confidence and cannot produce runnable output.')))
            }
        }
        else {
            $blocking.Add((New-ForgeFinding -Severity Blocking -Code 'DETECTION_UNRESOLVED' -Field 'Detection' -Message (
                'No file, registry, or usable native-MSI detection method can be resolved.')))
        }

        $spec.DecisionEvidence = $decisionEvidence.ToArray()
        $spec.BlockingFindings = $blocking.ToArray()
        $null = $spec.RecalculateReadiness()
        return $spec
    }
}

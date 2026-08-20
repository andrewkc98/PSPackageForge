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


<#
    [CommandSpec] is a class this module defines. A caller that only Import-Modules
    PSPackageForge -- rather than dot-sourcing it or running `using module` in the same
    session -- cannot construct one directly, because PowerShell 5.1 class visibility is
    session-scoped (plan §7 / L4). A hashtable is not scope-limited, so accepting one here
    is what lets an external evidence provider supply a structured command at all.

    This never parses a string into a command -- that is the whole point of the finding
    this closes. A dictionary that does not shape up (missing Executable, wrong element
    types) is a conversion failure, reported back as a Reason for COMMAND_EVIDENCE_UNUSABLE.
    It is never partially accepted or guessed at.
#>
function ConvertTo-ForgeCommandSpecFromDictionary {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Dictionary
    )

    $executable = $Dictionary['Executable']
    if ($executable -isnot [string] -or [string]::IsNullOrWhiteSpace($executable)) {
        return [PSCustomObject] @{
            Success     = $false
            CommandSpec = $null
            Reason      = "missing or empty required key 'Executable' (must be a non-empty string)."
        }
    }

    $argumentList = @()
    if ($Dictionary.Contains('ArgumentList') -and $null -ne $Dictionary['ArgumentList']) {
        $rawArguments = $Dictionary['ArgumentList']

        # A bare string IS IEnumerable (of chars), so it must be excluded explicitly or
        # 'setup.exe' would silently become @('s','e','t','u','p', ...).
        if ($rawArguments -is [string] -or $rawArguments -isnot [System.Collections.IEnumerable]) {
            return [PSCustomObject] @{ Success = $false; CommandSpec = $null; Reason = "'ArgumentList' must be an array of strings." }
        }
        foreach ($item in $rawArguments) {
            if ($item -isnot [string]) {
                return [PSCustomObject] @{ Success = $false; CommandSpec = $null; Reason = "'ArgumentList' must contain only strings." }
            }
        }
        $argumentList = @($rawArguments)
    }

    $expectedExitCodes = @(0)
    if ($Dictionary.Contains('ExpectedExitCodes') -and $null -ne $Dictionary['ExpectedExitCodes']) {
        $rawExitCodes = $Dictionary['ExpectedExitCodes']
        if ($rawExitCodes -is [string] -or $rawExitCodes -isnot [System.Collections.IEnumerable]) {
            return [PSCustomObject] @{ Success = $false; CommandSpec = $null; Reason = "'ExpectedExitCodes' must be an array of integers." }
        }
        foreach ($item in $rawExitCodes) {
            # Strict on purpose: a caller that wanted string parsing had every chance to
            # hand us an int and did not, so we do not silently coerce '0' into 0.
            if ($item -isnot [int]) {
                return [PSCustomObject] @{ Success = $false; CommandSpec = $null; Reason = "'ExpectedExitCodes' must contain only integers." }
            }
        }
        $expectedExitCodes = @($rawExitCodes)
    }

    $command = [CommandSpec]::new($executable, $argumentList, $expectedExitCodes)

    if ($Dictionary.Contains('WorkingDirectory') -and -not [string]::IsNullOrWhiteSpace([string] $Dictionary['WorkingDirectory'])) {
        $command.WorkingDirectory = [string] $Dictionary['WorkingDirectory']
    }

    return [PSCustomObject] @{ Success = $true; CommandSpec = $command; Reason = $null }
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

        <#
            Explicit structured command evidence wins. Strings are never reparsed into a
            command -- a [CommandSpec] instance is accepted as-is, and a dictionary
            (hashtable / ordered dictionary) is converted to one (L4: a plain
            Import-Module caller cannot construct [CommandSpec] directly). Anything else
            -- a string, a number, whatever -- is unusable and is reported as such rather
            than silently discarded, and the resolver falls through to the same
            fallback/blocking logic as if no record had been supplied at all.

            COMMAND_EVIDENCE_UNUSABLE is Blocking, not Warning: these records only exist
            because someone deliberately supplied an override, and packaging on the
            fallback instead of honouring an override we could not read is exactly the
            silent substitution this module exists to prevent. It also lives in
            BlockingFindings, which RecalculateReadiness counts -- severity and effect
            must agree.
        #>
        $installRecord   = $InstallerInfo.GetResolvedEvidence('InstallCommand')
        $installResolved = $false

        if ($null -ne $installRecord) {
            if ($installRecord.Value -is [CommandSpec]) {
                $spec.InstallCommand = $installRecord.Value
                $decisionEvidence.Add($installRecord.Clone())
                $installResolved = $true
            }
            elseif ($installRecord.Value -is [System.Collections.IDictionary]) {
                $conversion = ConvertTo-ForgeCommandSpecFromDictionary -Dictionary $installRecord.Value
                if ($conversion.Success) {
                    $spec.InstallCommand = $conversion.CommandSpec
                    $decisionEvidence.Add($installRecord.Clone())
                    $installResolved = $true
                }
                else {
                    $blocking.Add((New-ForgeFinding -Severity Blocking -Code 'COMMAND_EVIDENCE_UNUSABLE' -Field 'InstallCommand' -Message (
                        "InstallCommand evidence was a dictionary but could not be converted to a command: $($conversion.Reason)")))
                }
            }
            else {
                $valueTypeName = if ($null -eq $installRecord.Value) { '<null>' } else { $installRecord.Value.GetType().Name }
                $blocking.Add((New-ForgeFinding -Severity Blocking -Code 'COMMAND_EVIDENCE_UNUSABLE' -Field 'InstallCommand' -Message (
                    "InstallCommand evidence has value type '$valueTypeName', which is not a usable command representation. Commands are structured (a CommandSpec, or a dictionary with an Executable key) and are never parsed from strings.")))
            }

            if ($installResolved -and $installRecord.Confidence -eq [ConfidenceLevel]::Low) {
                $blocking.Add((New-ForgeFinding -Severity Blocking -Code 'INSTALL_COMMAND_LOW_CONFIDENCE' -Field 'InstallCommand' -Message (
                    'The accepted install command is only Low confidence and cannot produce runnable output.')))
            }
        }

        if (-not $installResolved) {
            if ($InstallerInfo.ContainerType -eq [ContainerType]::Msi) {
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
        }

        $uninstallRecord   = $InstallerInfo.GetResolvedEvidence('UninstallCommand')
        $uninstallResolved = $false

        if ($null -ne $uninstallRecord) {
            if ($uninstallRecord.Value -is [CommandSpec]) {
                $spec.UninstallCommand = $uninstallRecord.Value
                $decisionEvidence.Add($uninstallRecord.Clone())
                $uninstallResolved = $true
            }
            elseif ($uninstallRecord.Value -is [System.Collections.IDictionary]) {
                $conversion = ConvertTo-ForgeCommandSpecFromDictionary -Dictionary $uninstallRecord.Value
                if ($conversion.Success) {
                    $spec.UninstallCommand = $conversion.CommandSpec
                    $decisionEvidence.Add($uninstallRecord.Clone())
                    $uninstallResolved = $true
                }
                else {
                    $blocking.Add((New-ForgeFinding -Severity Blocking -Code 'COMMAND_EVIDENCE_UNUSABLE' -Field 'UninstallCommand' -Message (
                        "UninstallCommand evidence was a dictionary but could not be converted to a command: $($conversion.Reason)")))
                }
            }
            else {
                $valueTypeName = if ($null -eq $uninstallRecord.Value) { '<null>' } else { $uninstallRecord.Value.GetType().Name }
                $blocking.Add((New-ForgeFinding -Severity Blocking -Code 'COMMAND_EVIDENCE_UNUSABLE' -Field 'UninstallCommand' -Message (
                    "UninstallCommand evidence has value type '$valueTypeName', which is not a usable command representation. Commands are structured (a CommandSpec, or a dictionary with an Executable key) and are never parsed from strings.")))
            }

            if ($uninstallResolved -and $uninstallRecord.Confidence -eq [ConfidenceLevel]::Low) {
                $blocking.Add((New-ForgeFinding -Severity Blocking -Code 'UNINSTALL_COMMAND_LOW_CONFIDENCE' -Field 'UninstallCommand' -Message (
                    'The accepted uninstall command is only Low confidence and cannot produce runnable output.')))
            }
        }

        if (-not $uninstallResolved) {
            if ($InstallerInfo.MsiKind -eq [MsiKind]::Native -and
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

function Resolve-DetectionSpec {
    <#
        Resolves one unambiguous v1 detection rule. Multiple-rule boolean semantics are
        deliberately not invented; the resolver produces a single primary rule.
    #>
    [CmdletBinding()]
    [OutputType([DetectionSpec])]
    param(
        [Parameter(Mandatory)]
        [InstallerInfo] $InstallerInfo,

        [DetectionOperator] $VersionOperator = [DetectionOperator]::Exact
    )

    $targetRecord  = $InstallerInfo.GetResolvedEvidence('DetectionTarget')
    $versionRecord = $InstallerInfo.GetResolvedEvidence('DetectionTargetVersion')

    if ($null -ne $targetRecord -and -not [string]::IsNullOrWhiteSpace("$($targetRecord.Value)")) {
        $target = "$($targetRecord.Value)"
        $rule   = [DetectionSpec]::new()

        $rule.Kind             = [DetectionKind]::File
        $rule.Path             = Split-Path -Path $target -Parent
        $rule.FileName         = Split-Path -Path $target -Leaf
        $rule.UsesWildcardPath = $target -match '[*?]'
        $rule.Confidence       = $targetRecord.Confidence

        if ($null -ne $versionRecord -and -not [string]::IsNullOrWhiteSpace("$($versionRecord.Value)")) {
            $versionText   = "$($versionRecord.Value)"
            $parsedVersion = $null

            # A version-comparison rule must never be emitted from a value that cannot even be
            # parsed at generation time -- that would ship a rule the client-side script can
            # only fail on. Demote to existence-only and let DETECTION_LOW_CONFIDENCE stop the
            # scaffold until reviewed evidence supplies a parseable version.
            if ([version]::TryParse($versionText, [ref] $parsedVersion)) {
                $rule.Operator = $VersionOperator
                $rule.Value    = $versionText
                if ([int] $versionRecord.Confidence -lt [int] $rule.Confidence) {
                    $rule.Confidence = $versionRecord.Confidence
                }
                $rule.Rationale = "File detection from resolved DetectionTarget and DetectionTargetVersion evidence. Operator: $VersionOperator."
            }
            else {
                $rule.Operator   = [DetectionOperator]::Exists
                $rule.Value      = $null
                $rule.Confidence = [ConfidenceLevel]::Low
                $rule.Rationale  = "DetectionTargetVersion value '$versionText' could not be parsed as a System.Version; demoted to existence-only detection pending reviewed evidence."
            }
        }
        else {
            $rule.Operator  = [DetectionOperator]::Exists
            $rule.Value     = $null
            $rule.Rationale = 'File-existence detection because the selected target carries no usable file version.'
        }

        return $rule
    }

    if ($InstallerInfo.SupportsMsiUninstall -and -not [string]::IsNullOrWhiteSpace($InstallerInfo.ProductCode)) {
        $productCodeRecord = $InstallerInfo.GetResolvedEvidence('ProductCode')
        $rule              = [DetectionSpec]::new()
        $rule.Kind         = [DetectionKind]::MsiProductCode
        $rule.Operator     = [DetectionOperator]::Exact
        $rule.Value        = $InstallerInfo.ProductCode
        $rule.Confidence   = if ($null -ne $productCodeRecord) { $productCodeRecord.Confidence } else { [ConfidenceLevel]::Medium }
        $rule.Rationale    = 'MSI product-code fallback. Verify the installed registration during package testing.'
        return $rule
    }

    return $null
}

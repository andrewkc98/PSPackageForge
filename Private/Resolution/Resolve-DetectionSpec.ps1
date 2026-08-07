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
            $rule.Operator = $VersionOperator
            $rule.Value    = "$($versionRecord.Value)"
            if ([int] $versionRecord.Confidence -lt [int] $rule.Confidence) {
                $rule.Confidence = $versionRecord.Confidence
            }
            $rule.Rationale = "File detection from resolved DetectionTarget and DetectionTargetVersion evidence. Operator: $VersionOperator."
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

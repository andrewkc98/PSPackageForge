function Merge-InstallerEvidence {
    <#
        .SYNOPSIS
            Resolves a flat bag of EvidenceRecord objects into one winning record per field.

        .DESCRIPTION
            Providers emit evidence; they never construct a finished InstallerInfo. This is
            the merger that sits between them (plan §5.3).

            Merge policy (v1 -- deliberately simple):

              * Documented precedence, encoded as the numeric value of [EvidenceSource]:
                    UserOverride > DiscoveryJson > Registry > MsiDatabase
                                 > KnownQuirk > PeMetadata > Inferred
                Ties on precedence are broken by confidence, then by input order (stable).

              * When two sources of High confidence disagree on a CRITICAL field, apply
                precedence but emit an EVIDENCE_CONFLICT Warning and downgrade the winning
                field to Medium. The conflict is never resolved silently.

              * A high-confidence disagreement on a non-critical field is still surfaced,
                as Info, but does not downgrade confidence. The plan reserves the
                downgrade for decisions that can break a deployment.

            A full interactive conflict-resolution engine is roadmap. The finding is what
            matters in v1: the operator gets told, in the manifest and in the document,
            that two trustworthy sources disagreed and which one won.

        .PARAMETER Evidence
            The records to merge. Order is preserved for tie-breaking, so providers should
            be invoked in a stable order.

        .PARAMETER CriticalField
            Fields whose conflicts downgrade confidence and are reported as Warning rather
            than Info. Defaults to the five decisions named in plan §5.3.

        .OUTPUTS
            PSPackageForge.EvidenceMergeResult, with:
              Resolved  -- ordered dictionary of field name -> winning EvidenceRecord
              Findings  -- Finding[] raised during the merge
              Conflicts -- field names that had a high-confidence disagreement

        .EXAMPLE
            $merge = Merge-InstallerEvidence -Evidence $allRecords
            $merge.Resolved['ProductCode'].Source
    #>
    [CmdletBinding()]
    [OutputType('PSPackageForge.EvidenceMergeResult')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyCollection()]
        [EvidenceRecord[]] $Evidence,

        [Parameter()]
        [string[]] $CriticalField = @(
            'InstallCommand'
            'UninstallCommand'
            'InstallLocation'
            'SelectedContext'
            'DetectionTarget'
        )
    )

    begin {
        $collected = [System.Collections.Generic.List[EvidenceRecord]]::new()
    }

    process {
        foreach ($record in $Evidence) {
            if ($null -ne $record) { $collected.Add($record) }
        }
    }

    end {
        $resolved  = [ordered] @{}
        $findings  = [System.Collections.Generic.List[Finding]]::new()
        $conflicts = [System.Collections.Generic.List[string]]::new()

        # Preserve first-seen field order so the manifest is stable across runs.
        $fieldOrder = [System.Collections.Generic.List[string]]::new()
        $byField    = @{}

        foreach ($record in $collected) {
            if (-not $byField.ContainsKey($record.Field)) {
                $byField[$record.Field] = [System.Collections.Generic.List[EvidenceRecord]]::new()
                $fieldOrder.Add($record.Field)
            }
            $byField[$record.Field].Add($record)
        }

        foreach ($field in $fieldOrder) {
            $candidates = $byField[$field]

            # Stable ordering: precedence desc, then confidence desc, then input order.
            $index  = 0
            $ranked = $candidates |
                ForEach-Object {
                    [PSCustomObject] @{
                        Record     = $_
                        Precedence = $_.Precedence()
                        Confidence = [int] $_.Confidence
                        Order      = $index++
                    }
                } |
                Sort-Object -Property @{ Expression = 'Precedence'; Descending = $true },
                                      @{ Expression = 'Confidence'; Descending = $true },
                                      @{ Expression = 'Order'; Descending = $false }

            $winner = $ranked[0].Record.Clone()

            # A conflict is a DISAGREEMENT between High-confidence sources -- two sources
            # that agree are corroboration, which is the opposite of a problem.
            $highConfidence = @($candidates | Where-Object { $_.Confidence -eq [ConfidenceLevel]::High })
            $distinctValues = @(
                $highConfidence |
                    ForEach-Object { ConvertTo-ForgeComparableValue -Value $_.Value } |
                    Select-Object -Unique
            )

            if ($distinctValues.Count -gt 1) {
                $conflicts.Add($field)

                $detail = ($highConfidence |
                    ForEach-Object { '{0}={1}' -f $_.Source, (ConvertTo-ForgeDisplayValue -Value $_.Value) }) -join '; '

                $isCritical = $CriticalField -contains $field

                if ($isCritical) {
                    # Apply precedence, but say so loudly and stop claiming High.
                    $winner.Confidence = [ConfidenceLevel]::Medium

                    $note = 'Confidence downgraded to Medium by EVIDENCE_CONFLICT.'
                    $winner.Notes = if ([string]::IsNullOrWhiteSpace($winner.Notes)) {
                        $note
                    }
                    else {
                        '{0} {1}' -f $winner.Notes, $note
                    }

                    $findings.Add((New-ForgeFinding -Severity Warning -Code 'EVIDENCE_CONFLICT' -Field $field -Message (
                        "High-confidence sources disagree on critical field '{0}' ({1}). Resolved to '{2}' by precedence ({3}); confidence downgraded to Medium. Verify this value before deploying." -f
                            $field,
                            $detail,
                            (ConvertTo-ForgeDisplayValue -Value $winner.Value),
                            $winner.Source
                    )))
                }
                else {
                    $findings.Add((New-ForgeFinding -Severity Info -Code 'EVIDENCE_CONFLICT' -Field $field -Message (
                        "High-confidence sources disagree on '{0}' ({1}). Resolved to '{2}' by precedence ({3})." -f
                            $field,
                            $detail,
                            (ConvertTo-ForgeDisplayValue -Value $winner.Value),
                            $winner.Source
                    )))
                }
            }

            $resolved[$field] = $winner
        }

        [PSCustomObject] @{
            PSTypeName = 'PSPackageForge.EvidenceMergeResult'
            Resolved   = $resolved
            Findings   = $findings.ToArray()
            Conflicts  = $conflicts.ToArray()
        }
    }
}

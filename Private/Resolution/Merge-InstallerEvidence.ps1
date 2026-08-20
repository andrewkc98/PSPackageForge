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

              * For a CRITICAL field, the winner is still chosen by precedence, but the
                conflict check is not limited to High confidence. It looks at every
                candidate at the winner's OWN confidence tier and above. A High winner is
                checked against its High peers, same as before; a Medium winner -- one
                that only outranks a disagreeing High source on precedence, or that only
                has Medium peers -- is checked too, because a disagreement invisible below
                High is still a disagreement. On a hit: emit an EVIDENCE_CONFLICT Warning
                naming the field, the disagreeing source=value pairs, and the winner, then
                downgrade the winner's confidence exactly one level (High -> Medium,
                Medium -> Low; Low has nowhere to go and stays Low, but still warns). The
                conflict is never resolved silently, and it never costs zero levels of
                trust -- Medium -> Low is deliberate, not incidental: it is what trips the
                downstream *_LOW_CONFIDENCE Blocking gates in Resolve-PackageSpec, so a
                contradicted Medium-confidence decision cannot go on to produce runnable
                output.

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

            $winner     = $ranked[0].Record.Clone()
            $isCritical = $CriticalField -contains $field

            if ($isCritical) {
                <#
                    Critical fields are checked at the winner's OWN confidence tier and
                    above, not just High. A High winner is checked against High peers only
                    -- that reproduces the old behaviour. But a winner that only reached
                    Medium (because it out-ranked a disagreeing High source, or because
                    every candidate happened to be Medium) has to be checked too: a
                    disagreement that never touches High confidence is still a
                    disagreement on a field that can break a deployment, and it was
                    completely invisible before this changed. Checking only High/High
                    here would let precedence quietly paper over exactly the kind of
                    contradiction plan §2 says must never be silent.
                #>
                $tier           = $winner.Confidence
                $tierCandidates = @($candidates | Where-Object { [int] $_.Confidence -ge [int] $tier })
                $distinctValues = @(
                    $tierCandidates |
                        ForEach-Object { ConvertTo-ForgeComparableValue -Value $_.Value } |
                        Select-Object -Unique
                )

                if ($distinctValues.Count -gt 1) {
                    $conflicts.Add($field)

                    $detail = ($tierCandidates |
                        ForEach-Object { '{0}={1}' -f $_.Source, (ConvertTo-ForgeDisplayValue -Value $_.Value) }) -join '; '

                    <#
                        A conflict always costs the winner exactly one level of trust,
                        never zero. High -> Medium leaves a usable-but-flagged value.
                        Medium -> Low is the deliberate part: it is chosen specifically
                        because Resolve-PackageSpec's *_LOW_CONFIDENCE Blocking gates key
                        off Low, so a contradicted Medium-confidence decision stops being
                        able to produce runnable output rather than sailing through as an
                        unresolved Warning. A winner already at Low has nowhere lower to
                        go, but still gets the Warning -- the floor is not an excuse for
                        silence.
                    #>
                    $downgraded = switch ($tier) {
                        ([ConfidenceLevel]::High)   { [ConfidenceLevel]::Medium }
                        ([ConfidenceLevel]::Medium) { [ConfidenceLevel]::Low }
                        default                     { [ConfidenceLevel]::Low }
                    }

                    $winner.Confidence = $downgraded

                    $note = "Confidence downgraded to $downgraded by EVIDENCE_CONFLICT."
                    $winner.Notes = if ([string]::IsNullOrWhiteSpace($winner.Notes)) {
                        $note
                    }
                    else {
                        '{0} {1}' -f $winner.Notes, $note
                    }

                    $findings.Add((New-ForgeFinding -Severity Warning -Code 'EVIDENCE_CONFLICT' -Field $field -Message (
                        "{5}-confidence sources disagree on critical field '{0}' ({1}). Resolved to '{2}' by precedence ({3}); confidence downgraded to {4}. Verify this value before deploying." -f
                            $field,
                            $detail,
                            (ConvertTo-ForgeDisplayValue -Value $winner.Value),
                            $winner.Source,
                            $downgraded,
                            $tier
                    )))
                }
            }
            else {
                # Non-critical fields keep the original, narrower policy: only a
                # High/High disagreement is worth an operator's attention, and even then
                # it is Info, not a reason to touch confidence -- the plan reserves the
                # downgrade for decisions that can break a deployment.
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

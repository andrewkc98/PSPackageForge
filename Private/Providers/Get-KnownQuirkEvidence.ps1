<#
    Known-quirk evidence provider.

    Reads Config\known-quirks.psd1 (schema documented in that file's header comment) and,
    for every quirk whose Match criteria hold against the installer's own provider
    evidence, emits the quirk's configured Evidence entries with Source = KnownQuirk.

    Like Get-MsiEvidence, this never constructs a finished InstallerInfo and never decides
    how anything should be deployed (plan §5.3) -- it only supplies evidence, with honest
    provenance, for fields the real providers declined to answer. KnownQuirk ranks below
    MsiDatabase in EvidenceSource precedence by design (PSPackageForge.psm1): a quirk fills
    a gap, it never outvotes an observation.
#>

function Get-KnownQuirkEvidence {
    <#
        .SYNOPSIS
            Matches known-quirk configuration against gathered evidence and emits the
            configured evidence for every quirk that matches.

        .DESCRIPTION
            A quirk exists to answer the question a provider deliberately refused to
            answer -- most often a wrapper MSI's InstallLocation / DetectionTarget /
            UninstallCommand, which Get-MsiEvidence will not guess at (plan §8.1).

            Matching is evaluated against the identity fields (ProductName, Manufacturer,
            UpgradeCode, ProductCode) read from the RAW evidence gathered so far -- what the
            installer itself claims to be, per the providers that already ran -- and
            deliberately not against post-merge resolved winners. Get-InstallerInfo calls
            this before Merge-InstallerEvidence runs (see the hook comment there), so a
            quirk answers "does this file look like the installer I know about" from the
            same provider observations every other field is drawn from, independent of
            whatever AdditionalEvidence a caller also supplied for this run.

            A missing configuration file is normal -- most installers need no quirk -- and
            produces an empty result with no finding. A configuration file that exists but
            cannot be parsed, declares an unsupported SchemaVersion, or contains a quirk
            entry with no strong identifier (neither UpgradeCode nor ProductCode in its
            Match table) is reported via a KNOWN_QUIRK_CONFIG_INVALID Warning finding rather
            than a thrown exception: a broken quirk file must degrade to "no quirks applied
            this run", never abort identification of the installer itself.

        .PARAMETER Evidence
            The EvidenceRecord objects gathered by the real providers so far this run. Used
            only for matching (see identity note above); never mutated or re-emitted.

        .PARAMETER ConfigPath
            Path to the known-quirk psd1 file. Defaults to Config\known-quirks.psd1 under
            the module root. Parameterised so tests can point it at a synthetic config in
            $TestDrive without touching the real one.

        .OUTPUTS
            PSPackageForge.ProviderResult with Evidence[] and Findings[].
    #>
    [CmdletBinding()]
    [OutputType('PSPackageForge.ProviderResult')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [EvidenceRecord[]] $Evidence,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $ConfigPath = (Join-Path $script:ConfigRoot 'known-quirks.psd1')
    )

    $resultEvidence = [System.Collections.Generic.List[EvidenceRecord]]::new()
    $findings       = [System.Collections.Generic.List[Finding]]::new()

    # Bound to the two lists above by scope, not by value -- calling it after they have
    # been appended to returns the accumulated result at that point.
    $buildResult = {
        [PSCustomObject] @{
            PSTypeName = 'PSPackageForge.ProviderResult'
            Provider   = 'KnownQuirk'
            Evidence   = $resultEvidence.ToArray()
            Findings   = $findings.ToArray()
        }
    }

    # Absence of a quirk file is the common case, not an error: most installers are native
    # and need no quirk at all.
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return & $buildResult
    }

    try {
        $config = Import-PowerShellDataFile -Path $ConfigPath -ErrorAction Stop
    }
    catch {
        $findings.Add((New-ForgeFinding -Severity Warning -Code 'KNOWN_QUIRK_CONFIG_INVALID' -Message (
            "The known-quirk configuration at '{0}' could not be read: {1} No quirks were applied this run." -f
                $ConfigPath, $_.Exception.Message)))
        return & $buildResult
    }

    $schemaVersion = if ($config -and $config.Contains('SchemaVersion')) { "$($config.SchemaVersion)" } else { $null }
    if ($schemaVersion -ne '1.0') {
        $findings.Add((New-ForgeFinding -Severity Warning -Code 'KNOWN_QUIRK_CONFIG_INVALID' -Message (
            "The known-quirk configuration at '{0}' declares SchemaVersion '{1}', which this build does not recognise (expected '1.0'). No quirks were applied this run." -f
                $ConfigPath, $schemaVersion)))
        return & $buildResult
    }

    $quirks = if ($config.Contains('Quirks') -and $config.Quirks) { @($config.Quirks) } else { @() }
    if ($quirks.Count -eq 0) { return & $buildResult }

    $identity = @{}
    foreach ($field in @('ProductName', 'Manufacturer', 'UpgradeCode', 'ProductCode')) {
        $first            = $Evidence | Where-Object { $_.Field -eq $field } | Select-Object -First 1
        $identity[$field] = if ($first) { $first.Value } else { $null }
    }

    foreach ($quirk in $quirks) {
        if ($quirk -isnot [System.Collections.IDictionary]) {
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'KNOWN_QUIRK_CONFIG_INVALID' -Message (
                "An entry in the known-quirk configuration at '{0}' is not a valid quirk definition (expected a hashtable) and was skipped." -f $ConfigPath)))
            continue
        }

        $id = "$($quirk['Id'])".Trim()
        if ([string]::IsNullOrWhiteSpace($id)) {
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'KNOWN_QUIRK_CONFIG_INVALID' -Message (
                "A quirk entry in '{0}' has no Id and was skipped." -f $ConfigPath)))
            continue
        }

        $match = $quirk['Match']

        # A strong identifier is non-negotiable: matching on ProductName/Manufacturer text
        # alone is not reliable enough grounds to inject evidence into a package.
        if ($match -isnot [System.Collections.IDictionary] -or
                -not ($match.Contains('UpgradeCode') -or $match.Contains('ProductCode'))) {
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'KNOWN_QUIRK_CONFIG_INVALID' -Message (
                "Quirk '{0}' has no strong identifier (UpgradeCode or ProductCode) in its Match table and was skipped." -f $id)))
            continue
        }

        $isMatch = $true
        foreach ($key in $match.Keys) {
            $expected = $match[$key]

            if ($key -like '*Pattern') {
                # '<Field>Pattern' is tested with -match (case-insensitive) against the
                # identity value for <Field>, e.g. ManufacturerPattern -> Manufacturer.
                $targetField = $key.Substring(0, $key.Length - 'Pattern'.Length)
                $actual      = $identity[$targetField]

                if ($null -eq $actual -or -not ("$actual" -match $expected)) {
                    $isMatch = $false
                    break
                }
            }
            else {
                # Exact match, GUID-brace/case-insensitive via the same comparer the
                # merger uses so a quirk's notion of "the same value" never diverges from
                # the merge policy's.
                $actual = $identity[$key]
                if ((ConvertTo-ForgeComparableValue -Value $actual) -ne (ConvertTo-ForgeComparableValue -Value $expected)) {
                    $isMatch = $false
                    break
                }
            }
        }

        if (-not $isMatch) { continue }

        $entries       = if ($quirk.Contains('Evidence') -and $quirk['Evidence']) { @($quirk['Evidence']) } else { @() }
        $appliedFields = [System.Collections.Generic.List[string]]::new()

        foreach ($entry in $entries) {
            # A malformed evidence entry in a MATCHED quirk must not vanish silently: the
            # reviewer who wrote the quirk expects every entry to land, and a typo that
            # quietly drops one is exactly the kind of gap this module exists to surface.
            if ($entry -isnot [System.Collections.IDictionary]) {
                $findings.Add((New-ForgeFinding -Severity Warning -Code 'KNOWN_QUIRK_CONFIG_INVALID' -Message (
                    "Quirk '{0}' contains an evidence entry that is not a hashtable; it was skipped." -f $id)))
                continue
            }

            $field = "$($entry['Field'])".Trim()
            if ([string]::IsNullOrWhiteSpace($field)) {
                $findings.Add((New-ForgeFinding -Severity Warning -Code 'KNOWN_QUIRK_CONFIG_INVALID' -Message (
                    "Quirk '{0}' contains an evidence entry with no Field name; it was skipped." -f $id)))
                continue
            }

            $confidenceText    = "$($entry['Confidence'])".Trim()
            $isValidConfidence = [enum]::GetNames([ConfidenceLevel]) -contains $confidenceText

            # An unrecognised confidence name invalidates only this one evidence entry --
            # not the whole quirk -- and falls back to the safest floor, Low, rather than
            # guessing at what the author meant.
            $confidence = if ($isValidConfidence) { [enum]::Parse([ConfidenceLevel], $confidenceText) } else { [ConfidenceLevel]::Low }

            if (-not $isValidConfidence) {
                $findings.Add((New-ForgeFinding -Severity Warning -Code 'KNOWN_QUIRK_CONFIG_INVALID' -Field $field -Message (
                    "Quirk '{0}' evidence for field '{1}' has Confidence '{2}', which is not a recognised confidence level. Using Low." -f
                        $id, $field, $entry['Confidence'])))
            }

            # Hashtable-shaped values (command specs) pass through untouched --
            # Resolve-PackageSpec is what converts them; this provider only supplies them.
            $notes = if ($entry.Contains('Notes')) { "$($entry['Notes'])" } else { $null }
            $resultEvidence.Add([EvidenceRecord]::new($field, $entry['Value'], [EvidenceSource]::KnownQuirk, $confidence, $notes))
            $appliedFields.Add($field)
        }

        if ($appliedFields.Count -gt 0) {
            $findings.Add((New-ForgeFinding -Severity Info -Code 'KNOWN_QUIRK_APPLIED' -Message (
                "Known quirk '{0}' matched this installer and supplied evidence for: {1}." -f
                    $id, ($appliedFields -join ', '))))
        }
    }

    return & $buildResult
}

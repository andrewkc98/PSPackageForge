<#
    MSI evidence provider.

    Emits EvidenceRecord objects. It never constructs a finished InstallerInfo and never
    decides how anything should be deployed -- that is the resolver's job (plan §5.3).
#>

function Get-MsiCustomActionBaseType {
    <#
        .SYNOPSIS
            Extracts the base custom action type from a CustomAction.Type value.

        .DESCRIPTION
            CustomAction.Type packs a base type into the low six bits and a pile of
            scheduling and impersonation flags above them. Firefox ESR's wrapper actions are
            type 3074, which looks exotic until you mask it: 3074 -band 0x3F = 2, the plain
            "run an EXE from the Binary table" action, scheduled deferred and
            non-impersonating.

            Comparing the raw value against a list of known constants would miss it, which
            is how wrapper MSIs get mistaken for native ones.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Type
    )

    $parsed = 0
    if (-not [int]::TryParse($Type, [ref] $parsed)) { return -1 }

    return $parsed -band 0x3F
}


function Get-MsiEvidence {
    <#
        .SYNOPSIS
            Reads an MSI and emits evidence about what it is.

        .DESCRIPTION
            Covers the Property, SummaryInformation, File, Component, Directory, Feature and
            Upgrade tables (plan §8.1), plus the Binary and CustomAction tables, which are
            what distinguish a native MSI product from a wrapper around a vendor EXE.

            The most important thing this function does is decline to answer.

            For a wrapper MSI it deliberately emits **no** InstallLocation and **no**
            detection target. Firefox ESR's wrapper has a single component called
            EmptyComponent pointing at TempFolder: walking that chain succeeds and yields
            %TEMP%, which is where the payload is *extracted*, not where Firefox is
            *installed*. Reporting it would be a confident wrong answer of exactly the kind
            plan §2 forbids. Those values have to come from a known quirk or from
            reference-machine discovery, and they carry that provenance.

        .PARAMETER Path
            Path to an MSI, which is read and then analysed.

        .PARAMETER Database
            An already-read PSPackageForge.MsiDatabase.

            This parameter set exists so the classification rules can be tested against
            synthetic database shapes -- a wrapper with no File payload, a Directory chain
            that dead-ends in a property token -- without committing a vendor installer or
            downloading one in CI. The rules are the risky part; reading COM is not.

        .OUTPUTS
            PSPackageForge.ProviderResult with Evidence[] and Findings[].
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType('PSPackageForge.ProviderResult')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory, ParameterSetName = 'Database')]
        [PSTypeName('PSPackageForge.MsiDatabase')]
        [object] $Database
    )

    $evidence = [System.Collections.Generic.List[EvidenceRecord]]::new()
    $findings = [System.Collections.Generic.List[Finding]]::new()

    $database = if ($PSCmdlet.ParameterSetName -eq 'Database') { $Database } else { Read-MsiDatabase -Path $Path }

    $addEvidence = {
        param([string] $field, [object] $value, [ConfidenceLevel] $confidence, [string] $notes)

        if ($null -eq $value) { return }
        if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { return }

        $evidence.Add([EvidenceRecord]::new($field, $value, [EvidenceSource]::MsiDatabase, $confidence, $notes))
    }

    # ---- Identity ---------------------------------------------------------------------
    $properties = $database.Properties

    & $addEvidence 'ContainerType' 'Msi' ([ConfidenceLevel]::High) 'The supplied file opened as a Windows Installer database.'

    & $addEvidence 'ProductName'       $properties['ProductName']    ([ConfidenceLevel]::High) $null
    & $addEvidence 'Manufacturer'      $properties['Manufacturer']   ([ConfidenceLevel]::High) $null
    & $addEvidence 'ProductVersionRaw' $properties['ProductVersion'] ([ConfidenceLevel]::High) 'Exactly as reported by the MSI Property table; not normalised.'
    & $addEvidence 'ProductCode'       $properties['ProductCode']    ([ConfidenceLevel]::High) $null
    & $addEvidence 'UpgradeCode'       $properties['UpgradeCode']    ([ConfidenceLevel]::High) 'Identifies a related product family. It is NOT a supersedence relationship.'

    $productCodePresent = -not [string]::IsNullOrWhiteSpace($properties['ProductCode'])
    & $addEvidence 'ProductCodePresent' $productCodePresent ([ConfidenceLevel]::High) $null

    # ---- Architecture and language, from the summary Template --------------------------
    # Never inferred from the host PSPackageForge happens to be running on (plan §7.2).
    $template = $database.SummaryInformation['Template']

    if (-not [string]::IsNullOrWhiteSpace($template)) {
        $platform = ($template -split ';', 2)[0].Trim()
        $langPart = if (($template -split ';', 2).Count -gt 1) { ($template -split ';', 2)[1].Trim() } else { '' }

        $architecture = switch -Regex ($platform) {
            '^$'         { [ArchitectureType]::Neutral; break }
            '^Intel$'    { [ArchitectureType]::x86;     break }
            '^x64$'      { [ArchitectureType]::x64;     break }
            '^AMD64$'    { [ArchitectureType]::x64;     break }
            '^Arm64$'    { [ArchitectureType]::Arm64;   break }
            '^Arm$'      { [ArchitectureType]::Arm64;   break }
            default      { [ArchitectureType]::Unknown }
        }

        if ($architecture -eq [ArchitectureType]::Unknown) {
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'MSI_PLATFORM_UNRECOGNISED' -Field 'Architecture' -Message (
                "The summary Template platform '{0}' is not recognised, so the package architecture could not be determined. Set it manually before deploying." -f $platform)))
        }
        else {
            & $addEvidence 'Architecture' $architecture.ToString() ([ConfidenceLevel]::High) (
                "From the MSI summary Template '$template'.")
        }

        # Template language wins over ProductLanguage: it is the package's declared set.
        $language = if ($langPart) { ($langPart -split ',')[0].Trim() } else { $properties['ProductLanguage'] }
        & $addEvidence 'Language' $language ([ConfidenceLevel]::High) $null
    }
    else {
        $findings.Add((New-ForgeFinding -Severity Warning -Code 'MSI_TEMPLATE_MISSING' -Field 'Architecture' -Message (
            'The MSI summary stream has no Template value, so the package architecture is unknown. Do not assume x64.')))
    }

    # ---- Native or wrapper (plan §8.1) --------------------------------------------------
    $exeLaunchingActions = @(
        $database.CustomActions | Where-Object {
            # 2 = EXE from the Binary table, 34 = EXE from a directory, 50 = EXE from a property.
            (Get-MsiCustomActionBaseType -Type $_.Type) -in @(2, 34, 50)
        }
    )

    $hasPayload = $database.Files.Count -gt 0

    if (-not $hasPayload) {
        # Decisive. An MSI that installs no files is not installing a product itself.
        $msiKind = [MsiKind]::Wrapper

        if ($exeLaunchingActions.Count -gt 0) {
            $payloadType       = [PayloadType]::Exe
            $payloadConfidence = [ConfidenceLevel]::High
            $payloadNotes      = 'Executable-launching custom action evidence identifies the wrapped payload as an EXE.'
        }
        else {
            $payloadType       = [PayloadType]::Unknown
            $payloadConfidence = [ConfidenceLevel]::Low
            $payloadNotes      = 'The MSI has no installable File payload, but no evidence identifies what the wrapper launches.'
        }

        $reason = if ($exeLaunchingActions.Count -gt 0) {
            "it has no File payload and runs an embedded executable via custom action(s): $(($exeLaunchingActions | ForEach-Object { $_.Action }) -join ', ')"
        }
        else {
            'it has no File payload at all'
        }

        & $addEvidence 'MsiKind' 'Wrapper' ([ConfidenceLevel]::High) "Classified as a wrapper because $reason."

        $findings.Add((New-ForgeFinding -Severity Warning -Code 'MSI_WRAPPER_DETECTED' -Field 'MsiKind' -Message (
            "This MSI is a wrapper around a vendor executable ({0}). A ProductCode may be present, but the vendor's own installer performs the work, so 'msiexec /x' will not uninstall the product. Use the vendor uninstaller." -f $reason)))
    }
    elseif ($exeLaunchingActions.Count -gt 0) {
        # Has real payload AND launches an embedded executable. Honest answer: mixed.
        $msiKind     = [MsiKind]::Unknown
        $payloadType = [PayloadType]::Mixed
        $payloadConfidence = [ConfidenceLevel]::High
        $payloadNotes      = 'The MSI has an installable file payload and executable-launching custom actions.'

        & $addEvidence 'MsiKind' 'Unknown' ([ConfidenceLevel]::Low) (
            'The package installs files of its own but also launches an embedded executable, so it is neither cleanly native nor cleanly a wrapper.')

        $findings.Add((New-ForgeFinding -Severity Blocking -Code 'MSI_KIND_AMBIGUOUS' -Field 'MsiKind' -Message (
            "This MSI installs {0} file(s) but also runs an embedded executable via custom action(s): {1}. Whether 'msiexec /x' fully uninstalls it cannot be determined offline. Verify uninstall behaviour on a reference machine before deploying." -f
                $database.Files.Count, (($exeLaunchingActions | ForEach-Object { $_.Action }) -join ', '))))
    }
    else {
        $msiKind     = [MsiKind]::Native
        $payloadType = [PayloadType]::Msi
        $payloadConfidence = [ConfidenceLevel]::High
        $payloadNotes      = 'The MSI contains a normal installable file payload.'

        & $addEvidence 'MsiKind' 'Native' ([ConfidenceLevel]::High) (
            "Normal payload ($($database.Files.Count) file(s), $($database.Features.Count) feature(s)) with no embedded executable custom actions.")
    }

    & $addEvidence 'PayloadType' $payloadType.ToString() $payloadConfidence $payloadNotes

    # A ProductCode can exist syntactically without producing installed-product behaviour.
    $supportsMsiUninstall = $productCodePresent -and $msiKind -eq [MsiKind]::Native

    & $addEvidence 'SupportsMsiUninstall' $supportsMsiUninstall ([ConfidenceLevel]::High) $(
        if ($productCodePresent -and -not $supportsMsiUninstall) {
            'A ProductCode is present, but this package does not register an installed product that msiexec can remove.'
        }
        else {
            $null
        }
    )

    # ---- Install context evidence (one signal among several -- plan §8.4) ---------------
    if ($properties.ContainsKey('ALLUSERS')) {
        $allUsers = "$($properties['ALLUSERS'])".Trim()

        $contextValue = switch ($allUsers) {
            '1' { 'System' }
            '2' { 'Unknown' }   # per-machine if elevated, per-user otherwise
            ''  { 'User' }
            default { 'Unknown' }
        }

        $note = switch ($allUsers) {
            '1'     { 'MSI property ALLUSERS=1 requests a per-machine install.' }
            '2'     { 'MSI property ALLUSERS=2 means per-machine when elevated and per-user otherwise, so it does not determine context on its own.' }
            default { "MSI property ALLUSERS='$allUsers'." }
        }

        if ($contextValue -ne 'Unknown') {
            & $addEvidence 'SelectedContext' $contextValue ([ConfidenceLevel]::Medium) $note
        }
        else {
            $findings.Add((New-ForgeFinding -Severity Info -Code 'MSI_ALLUSERS_AMBIGUOUS' -Field 'SelectedContext' -Message $note))
        }
    }

    if ("$($properties['MSIINSTALLPERUSER'])".Trim() -eq '1') {
        & $addEvidence 'SelectedContext' 'User' ([ConfidenceLevel]::Medium) 'MSI property MSIINSTALLPERUSER=1 requests a per-user install.'
    }

    # ---- Install location and detection target -- native packages only -----------------
    if ($msiKind -eq [MsiKind]::Native) {
        $componentsById = @{}
        foreach ($component in $database.Components) { $componentsById[$component.Component] = $component }

        $primary          = Select-MsiPrimaryFile -Database $database
        $targetConfidence = $null

        if ($primary) {
            $component = $componentsById[$primary.Component]

            if ($component) {
                $resolution = Resolve-MsiInstallPath -Database $database -DirectoryId $component.Directory -ComponentCondition $component.Condition

                foreach ($finding in $resolution.Findings) { $findings.Add($finding) }

                if ($resolution.EnvironmentPath) {
                    & $addEvidence 'InstallLocation' $resolution.EnvironmentPath $resolution.Confidence (
                        "Resolved through File -> Component -> Directory as $($resolution.TokenPath).")

                    # Directory resolution and target selection answer different questions.
                    # Even a High-confidence directory chain cannot make a heuristic choice
                    # among multiple files High confidence.
                    $targetConfidence = if ($resolution.Confidence -eq [ConfidenceLevel]::Low) {
                        [ConfidenceLevel]::Low
                    }
                    else {
                        [ConfidenceLevel]::Medium
                    }

                    & $addEvidence 'DetectionTarget' ('{0}\{1}' -f $resolution.EnvironmentPath, $primary.FileName) $targetConfidence (
                        "Selected '$($primary.File)' from the MSI File table using this heuristic: $($primary.SelectionRationale)")

                    $findings.Add((New-ForgeFinding -Severity Info -Code 'MSI_DETECTION_TARGET_INFERRED' -Field 'DetectionTarget' -Message (
                        "The install directory resolved at {0} confidence, but choosing '{1}' as the detection target is heuristic ({2}); target confidence is {3}. Review the selected file before deployment." -f
                            $resolution.Confidence, $primary.FileName, $primary.SelectionRationale, $targetConfidence)))

                    if ($resolution.IsUserScope) {
                        & $addEvidence 'SelectedContext' 'User' ([ConfidenceLevel]::Medium) (
                            "The payload installs under $($resolution.RootToken), which is inside a user profile.")
                    }
                }
            }
        }

        if ($primary -and -not [string]::IsNullOrWhiteSpace($primary.Version)) {
            # The File table version is what Get-Item .VersionInfo will report on disk, and
            # it is regularly NOT the same as the MSI ProductVersion. Detection must compare
            # against the file, so the file's version is what gets recorded.
            $versionConfidence = if ($null -ne $targetConfidence) { $targetConfidence } else { [ConfidenceLevel]::Medium }
            & $addEvidence 'DetectionTargetVersion' $primary.Version $versionConfidence (
                "File version of the heuristically selected detection target '$($primary.FileName)' from the MSI File table.")

            $productVersion = "$($properties['ProductVersion'])".Trim()
            if ($productVersion -and (ConvertTo-ForgeComparableValue -Value $productVersion) -ne (ConvertTo-ForgeComparableValue -Value $primary.Version)) {
                $findings.Add((New-ForgeFinding -Severity Info -Code 'MSI_VERSION_DIFFERS_FROM_FILE' -Field 'DetectionTargetVersion' -Message (
                    "The MSI ProductVersion ({0}) differs from the version of the detection target file {1} ({2}). File-based detection must compare against the file version, not the ProductVersion." -f
                        $productVersion, $primary.FileName, $primary.Version)))
            }
        }
        elseif ($primary) {
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'MSI_FILE_VERSION_MISSING' -Field 'DetectionTargetVersion' -Message (
                "The primary payload file '{0}' carries no version in the MSI File table, so a file-version detection rule cannot be built from the package alone. Use an existence check, or supply a version from reference-machine discovery." -f $primary.FileName)))
        }
    }
    else {
        # The refusal that makes the Firefox case honest.
        $findings.Add((New-ForgeFinding -Severity Info -Code 'MSI_PAYLOAD_NOT_INTROSPECTABLE' -Field 'InstallLocation' -Message (
            'No install location or detection target was derived from this MSI: its Directory table describes where the payload is extracted, not where the product is installed. These values must come from a known quirk or from reference-machine discovery, and will be attributed to that source.')))
    }

    # ---- Upgrade relationships ----------------------------------------------------------
    if ($database.Upgrades.Count -gt 0) {
        $relatedCodes = @($database.Upgrades | ForEach-Object { $_.UpgradeCode } | Select-Object -Unique)

        $findings.Add((New-ForgeFinding -Severity Info -Code 'MSI_UPGRADE_TABLE_PRESENT' -Field 'UpgradeCode' -Message (
            'Related MSI products may share the UpgradeCode(s) {0}; review them when configuring upgrade or supersedence behaviour. An UpgradeCode is a product family identifier, not a ConfigMgr supersedence relationship.' -f ($relatedCodes -join ', '))))
    }

    [PSCustomObject] @{
        PSTypeName = 'PSPackageForge.ProviderResult'
        Provider   = 'Msi'
        Evidence   = $evidence.ToArray()
        Findings   = $findings.ToArray()
        Raw        = $database
    }
}


function Select-MsiPrimaryFile {
    <#
        .SYNOPSIS
            Picks the file a detection rule should target.

        .DESCRIPTION
            Preference order, most to least specific:

              1. An executable whose base name resembles the product name.
              2. The largest versioned executable.
              3. The largest versioned file of any kind.

            Size is a crude proxy for "the main binary", but it is a stable and explicable
            one, and the choice is always reported in the generated document so a reviewer
            can override it. Guessing silently would be the problem; guessing visibly is
            what a scaffolder is for.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [PSTypeName('PSPackageForge.MsiDatabase')]
        [object] $Database
    )

    if ($Database.Files.Count -eq 0) { return $null }

    $withSize = $Database.Files | ForEach-Object {
        $size = 0
        [void] [int64]::TryParse($_.FileSize, [ref] $size)

        $_ | Add-Member -NotePropertyName 'SizeBytes' -NotePropertyValue $size -Force -PassThru
    }

    $executables = @($withSize | Where-Object { $_.FileName -match '\.exe$' })

    $productName = "$($Database.Properties['ProductName'])"
    if ($productName) {
        # Compare on letters and digits only: '7-Zip 26.02 (x64 edition)' should match 7zFM.exe.
        $normalisedProduct = ($productName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()

        $named = @($executables | Where-Object {
            $base = ([System.IO.Path]::GetFileNameWithoutExtension($_.FileName) -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
            $base -and $normalisedProduct -and ($normalisedProduct.StartsWith($base) -or $base.StartsWith($normalisedProduct))
        })

        if ($named.Count -gt 0) {
            $selected = $named | Sort-Object -Property SizeBytes -Descending | Select-Object -First 1
            $selected | Add-Member -NotePropertyName SelectionRationale -NotePropertyValue 'executable base name resembles ProductName; largest match wins' -Force
            return $selected
        }
    }

    $versionedExe = @($executables | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Version) })
    if ($versionedExe.Count -gt 0) {
        $selected = $versionedExe | Sort-Object -Property SizeBytes -Descending | Select-Object -First 1
        $selected | Add-Member -NotePropertyName SelectionRationale -NotePropertyValue 'largest versioned executable' -Force
        return $selected
    }

    if ($executables.Count -gt 0) {
        $selected = $executables | Sort-Object -Property SizeBytes -Descending | Select-Object -First 1
        $selected | Add-Member -NotePropertyName SelectionRationale -NotePropertyValue 'largest executable; no versioned executable was available' -Force
        return $selected
    }

    $selected = $withSize | Sort-Object -Property SizeBytes -Descending | Select-Object -First 1
    $selected | Add-Member -NotePropertyName SelectionRationale -NotePropertyValue 'largest payload file; no executable was available' -Force
    return $selected
}

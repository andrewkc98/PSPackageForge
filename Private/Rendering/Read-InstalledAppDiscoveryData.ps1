function ConvertTo-InstalledAppDiscoveryDocument {
    <#
        .SYNOPSIS
            Converts live installed-application discovery into the versioned JSON shape.

        .DESCRIPTION
            Live results retain Registry provenance while they are in memory. This function
            serialises those records without relying on PowerShell's enum JSON behaviour,
            which differs between Windows PowerShell 5.1 and newer editions. Import is the
            boundary that re-attributes reviewed records to DiscoveryJson.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Discovery
    )

    $matchDocuments = @(
        foreach ($match in @($Discovery.Matches)) {
            [ordered] @{
                MatchId          = "$($match.MatchId)"
                DisplayName      = "$($match.DisplayName)"
                RegistryIdentity = [ordered] @{
                    Hive   = "$($match.RegistryIdentity.Hive)"
                    View   = "$($match.RegistryIdentity.View)"
                    SubKey = "$($match.RegistryIdentity.SubKey)"
                }
                Evidence         = @($match.Evidence | ForEach-Object { $_.ToOrderedDictionary() })
                ResolvedEvidence = @($match.ResolvedEvidence | ForEach-Object { $_.ToOrderedDictionary() })
                Findings         = @($match.Findings | ForEach-Object { $_.ToOrderedDictionary() })
            }
        }
    )

    return [ordered] @{
        SchemaVersion  = "$($Discovery.SchemaVersion)"
        GeneratedAtUtc = "$($Discovery.GeneratedAtUtc)"
        Query          = [ordered] @{
            DisplayNameLike = "$($Discovery.Query.DisplayNameLike)"
        }
        Matches        = $matchDocuments
        Findings       = @($Discovery.Findings | ForEach-Object { $_.ToOrderedDictionary() })
    }
}


function ConvertFrom-InstalledAppDiscoveryFinding {
    [CmdletBinding()]
    [OutputType([Finding])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Finding
    )

    $severityText = "$(Get-DocumentOptionalProperty -InputObject $Finding -Name 'Severity')"
    if ($severityText -notin @('Info', 'Warning', 'Blocking')) {
        throw [System.IO.InvalidDataException]::new(
            "Discovery finding severity '$severityText' is invalid.")
    }

    $code = "$(Get-DocumentOptionalProperty -InputObject $Finding -Name 'Code')"
    if ($code -notmatch '^[A-Z][A-Z0-9_]*$') {
        throw [System.IO.InvalidDataException]::new(
            "Discovery finding code '$code' is invalid.")
    }

    $message = "$(Get-DocumentOptionalProperty -InputObject $Finding -Name 'Message')"
    if ([string]::IsNullOrWhiteSpace($message)) {
        throw [System.IO.InvalidDataException]::new(
            "Discovery finding '$code' has no message.")
    }

    $field = "$(Get-DocumentOptionalProperty -InputObject $Finding -Name 'Field')"
    return New-ForgeFinding -Severity $severityText -Code $code -Message $message -Field $field
}


function ConvertFrom-InstalledAppDiscoveryCommandValue {
    <#
        Converts a JSON command object into the dictionary shape Resolve-PackageSpec accepts.
        Strings are never parsed here: parsing belongs on the live Windows registry boundary.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Value,

        [Parameter(Mandatory)]
        [string] $Field
    )

    $executable = Get-DocumentOptionalProperty -InputObject $Value -Name 'Executable'
    if ($executable -isnot [string] -or [string]::IsNullOrWhiteSpace($executable)) {
        throw [System.IO.InvalidDataException]::new(
            "Discovery evidence field '$Field' contains a command with no executable.")
    }

    $arguments = @()
    $rawArguments = Get-DocumentOptionalProperty -InputObject $Value -Name 'ArgumentList'
    if ($null -ne $rawArguments) {
        foreach ($argument in @($rawArguments)) {
            if ($argument -isnot [string]) {
                throw [System.IO.InvalidDataException]::new(
                    "Discovery evidence field '$Field' contains a non-string command argument.")
            }
            $arguments += $argument
        }
    }

    $exitCodes = @()
    $rawExitCodes = Get-DocumentOptionalProperty -InputObject $Value -Name 'ExpectedExitCodes'
    if ($null -eq $rawExitCodes) {
        throw [System.IO.InvalidDataException]::new(
            "Discovery evidence field '$Field' contains a command with no ExpectedExitCodes.")
    }
    foreach ($code in @($rawExitCodes)) {
        $parsedCode = 0
        if (-not [int]::TryParse("$code", [ref] $parsedCode)) {
            throw [System.IO.InvalidDataException]::new(
                "Discovery evidence field '$Field' contains invalid exit code '$code'.")
        }
        $exitCodes += $parsedCode
    }

    $dictionary = [ordered] @{
        Executable        = $executable
        ArgumentList      = [string[]] $arguments
        ExpectedExitCodes = [int[]] $exitCodes
    }
    $workingDirectory = Get-DocumentOptionalProperty -InputObject $Value -Name 'WorkingDirectory'
    if ($null -ne $workingDirectory -and -not [string]::IsNullOrWhiteSpace("$workingDirectory")) {
        $dictionary['WorkingDirectory'] = "$workingDirectory"
    }
    return $dictionary
}


function ConvertFrom-InstalledAppDiscoveryEvidence {
    [CmdletBinding()]
    [OutputType([EvidenceRecord])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Evidence,

        [Parameter(Mandatory)]
        [string] $MatchId
    )

    $field = "$(Get-DocumentOptionalProperty -InputObject $Evidence -Name 'Field')"
    if ([string]::IsNullOrWhiteSpace($field)) {
        throw [System.IO.InvalidDataException]::new('Discovery evidence contains an empty Field.')
    }

    $sourceText = "$(Get-DocumentOptionalProperty -InputObject $Evidence -Name 'Source')"
    if ($sourceText -ne 'Registry') {
        throw [System.IO.InvalidDataException]::new(
            "Discovery evidence field '$field' has source '$sourceText'; schema 1.0 requires Registry.")
    }

    $confidenceText = "$(Get-DocumentOptionalProperty -InputObject $Evidence -Name 'Confidence')"
    if ($confidenceText -notin @('Low', 'Medium', 'High')) {
        throw [System.IO.InvalidDataException]::new(
            "Discovery evidence field '$field' has invalid confidence '$confidenceText'.")
    }

    $value = Get-DocumentOptionalProperty -InputObject $Evidence -Name 'Value'
    if ($null -eq $value -or
        ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
        throw [System.IO.InvalidDataException]::new(
            "Discovery evidence field '$field' has an empty Value.")
    }
    if ($field -in @('InstallCommand', 'UninstallCommand')) {
        $value = ConvertFrom-InstalledAppDiscoveryCommandValue -Value $value -Field $field
    }

    $notes = "$(Get-DocumentOptionalProperty -InputObject $Evidence -Name 'Notes')"
    $importNote = "Imported from reviewed discovery JSON match '$MatchId' (original source Registry)."
    $notes = if ([string]::IsNullOrWhiteSpace($notes)) { $importNote } else { "$notes $importNote" }

    $confidence = Get-ForgeEnumValue -Value $confidenceText -Type ([ConfidenceLevel]) `
        -Default ([ConfidenceLevel]::Low)
    return [EvidenceRecord]::new($field, $value, [EvidenceSource]::DiscoveryJson, $confidence, $notes)
}


function Read-InstalledAppDiscoveryData {
    <#
        .SYNOPSIS
            Reads, validates, and selects one installed-application discovery match.

        .DESCRIPTION
            A sole match is selected automatically. A document containing several matches
            requires MatchId so unrelated installed applications can never be merged into a
            synthetic identity. ResolvedEvidence from disk is deliberately ignored: raw
            evidence is merged again with the current installer and current merge policy.
    #>
    [CmdletBinding()]
    [OutputType('PSPackageForge.ProviderResult')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [string] $MatchId
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("Discovery data is not a file: $resolvedPath")
    }

    try {
        $document = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw [System.IO.InvalidDataException]::new(
            "Discovery data '$resolvedPath' is not valid JSON: $($_.Exception.Message)", $_.Exception)
    }

    $schemaVersion = "$(Get-DocumentOptionalProperty -InputObject $document -Name 'SchemaVersion')"
    if ($schemaVersion -ne "$script:DiscoverySchemaVersion") {
        throw [System.IO.InvalidDataException]::new(
            "Discovery data schema '$schemaVersion' is not supported; expected '$script:DiscoverySchemaVersion'.")
    }

    $generatedAtValue = Get-DocumentOptionalProperty -InputObject $document -Name 'GeneratedAtUtc'
    $generatedAtText = if ($generatedAtValue -is [DateTime]) {
        $generatedAtValue.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    else {
        "$generatedAtValue"
    }
    $generatedAt = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact(
            $generatedAtText,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref] $generatedAt)) {
        throw [System.IO.InvalidDataException]::new(
            "Discovery data GeneratedAtUtc '$generatedAtText' is not a round-trip ISO-8601 timestamp.")
    }

    $query = Get-DocumentOptionalProperty -InputObject $document -Name 'Query'
    $displayNameLike = "$(Get-DocumentOptionalProperty -InputObject $query -Name 'DisplayNameLike')"
    if ([string]::IsNullOrWhiteSpace($displayNameLike)) {
        throw [System.IO.InvalidDataException]::new(
            'Discovery data Query.DisplayNameLike must be a non-empty string.')
    }

    $availableMatches = @(@(Get-DocumentOptionalProperty -InputObject $document -Name 'Matches') |
        Where-Object { $null -ne $_ })
    if ($availableMatches.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new('Discovery data contains no installed-application matches.')
    }

    foreach ($candidate in $availableMatches) {
        $candidateDisplayName = "$(Get-DocumentOptionalProperty -InputObject $candidate -Name 'DisplayName')"
        if ([string]::IsNullOrWhiteSpace($candidateDisplayName)) {
            throw [System.IO.InvalidDataException]::new(
                'Every discovery match must contain a non-empty DisplayName.')
        }

        $identity = Get-DocumentOptionalProperty -InputObject $candidate -Name 'RegistryIdentity'
        $hive = "$(Get-DocumentOptionalProperty -InputObject $identity -Name 'Hive')"
        $view = "$(Get-DocumentOptionalProperty -InputObject $identity -Name 'View')"
        $subKey = "$(Get-DocumentOptionalProperty -InputObject $identity -Name 'SubKey')"
        if ($hive -notin @('LocalMachine', 'CurrentUser') -or
            $view -notin @('Registry32', 'Registry64') -or
            [string]::IsNullOrWhiteSpace($subKey) -or
            $subKey -match '[\x00-\x1F\x7F]') {
            throw [System.IO.InvalidDataException]::new(
                "Discovery match '$candidateDisplayName' has an invalid RegistryIdentity.")
        }

        $actualId = "$(Get-DocumentOptionalProperty -InputObject $candidate -Name 'MatchId')"
        $expectedId = Get-InstalledAppMatchId -Hive $hive -View $view -SubKey $subKey
        if (-not [string]::Equals($actualId, $expectedId, [StringComparison]::OrdinalIgnoreCase)) {
            throw [System.IO.InvalidDataException]::new(
                "Discovery match '$candidateDisplayName' has a MatchId that does not match its RegistryIdentity.")
        }
    }

    $matchIds = @($availableMatches | ForEach-Object { "$(Get-DocumentOptionalProperty -InputObject $_ -Name 'MatchId')" })
    if (@($matchIds | Where-Object { $_ -notmatch '^[0-9A-Fa-f]{64}$' }).Count -gt 0 -or
        @($matchIds | Sort-Object -Unique).Count -ne $matchIds.Count) {
        throw [System.IO.InvalidDataException]::new(
            'Discovery data MatchId values must be unique 64-character SHA-256 hexadecimal strings.')
    }

    $selected = $null
    if ([string]::IsNullOrWhiteSpace($MatchId)) {
        if ($availableMatches.Count -ne 1) {
            throw [System.IO.InvalidDataException]::new(
                "Discovery data contains $($availableMatches.Count) matches. Supply -DiscoveryMatchId with one of: $($matchIds -join ', ')")
        }
        $selected = $availableMatches[0]
    }
    else {
        $selectedMatches = @($availableMatches | Where-Object {
                [string]::Equals("$(Get-DocumentOptionalProperty -InputObject $_ -Name 'MatchId')", $MatchId,
                    [StringComparison]::OrdinalIgnoreCase)
            })
        if ($selectedMatches.Count -ne 1) {
            throw [System.IO.InvalidDataException]::new(
                "Discovery match '$MatchId' was not found in '$resolvedPath'.")
        }
        $selected = $selectedMatches[0]
    }

    $selectedId = "$(Get-DocumentOptionalProperty -InputObject $selected -Name 'MatchId')"
    $evidence = [System.Collections.Generic.List[EvidenceRecord]]::new()
    foreach ($row in @(@(Get-DocumentOptionalProperty -InputObject $selected -Name 'Evidence') |
            Where-Object { $null -ne $_ })) {
        $evidence.Add((ConvertFrom-InstalledAppDiscoveryEvidence -Evidence $row -MatchId $selectedId))
    }
    if ($evidence.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new(
            "Discovery match '$selectedId' contains no evidence.")
    }

    $findings = [System.Collections.Generic.List[Finding]]::new()
    foreach ($row in @(@(Get-DocumentOptionalProperty -InputObject $document -Name 'Findings') |
            Where-Object { $null -ne $_ })) {
        $findings.Add((ConvertFrom-InstalledAppDiscoveryFinding -Finding $row))
    }
    foreach ($row in @(@(Get-DocumentOptionalProperty -InputObject $selected -Name 'Findings') |
            Where-Object { $null -ne $_ })) {
        $findings.Add((ConvertFrom-InstalledAppDiscoveryFinding -Finding $row))
    }

    [PSCustomObject] @{
        PSTypeName = 'PSPackageForge.ProviderResult'
        Provider   = 'DiscoveryJson'
        MatchId    = $selectedId
        Evidence   = $evidence.ToArray()
        Findings   = $findings.ToArray()
        Path       = $resolvedPath
    }
}

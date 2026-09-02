function Get-InstalledAppMatchId {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('LocalMachine', 'CurrentUser')]
        [string] $Hive,

        [Parameter(Mandatory)]
        [ValidateSet('Registry32', 'Registry64')]
        [string] $View,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SubKey
    )

    $identityText = '{0}|{1}|{2}' -f
        $Hive.ToLowerInvariant(),
        $View.ToLowerInvariant(),
        $SubKey.ToLowerInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($identityText))
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha256.Dispose() }
}


function Split-ForgeWindowsCommandLine {
    <# Parses the Windows CRT quoting subset emitted by ConvertTo-CommandString. #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $CommandLine
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine) -or $CommandLine.IndexOf([char] 0) -ge 0) {
        return [PSCustomObject] @{ Success = $false; Tokens = @(); Reason = 'The command is empty or contains a null character.' }
    }

    $tokens = [System.Collections.Generic.List[string]]::new()
    $length = $CommandLine.Length
    $index = 0

    while ($index -lt $length) {
        while ($index -lt $length -and [char]::IsWhiteSpace($CommandLine[$index])) { $index++ }
        if ($index -ge $length) { break }

        $builder = [System.Text.StringBuilder]::new()
        $inQuotes = $false
        $started = $false
        while ($index -lt $length) {
            $character = $CommandLine[$index]
            if (-not $inQuotes -and [char]::IsWhiteSpace($character)) { break }

            if ($character -eq [char] 92) {
                $slashCount = 0
                while ($index -lt $length -and $CommandLine[$index] -eq [char] 92) {
                    $slashCount++
                    $index++
                }
                if ($index -lt $length -and $CommandLine[$index] -eq [char] 34) {
                    if ($slashCount -gt 1) { [void] $builder.Append([char] 92, [int] [math]::Floor($slashCount / 2)) }
                    if (($slashCount % 2) -eq 1) {
                        [void] $builder.Append([char] 34)
                        $index++
                    }
                    else {
                        $inQuotes = -not $inQuotes
                        $index++
                    }
                }
                else {
                    [void] $builder.Append([char] 92, $slashCount)
                }
                $started = $true
                continue
            }

            if ($character -eq [char] 34) {
                if ($inQuotes -and ($index + 1) -lt $length -and $CommandLine[$index + 1] -eq [char] 34) {
                    [void] $builder.Append([char] 34)
                    $index += 2
                }
                else {
                    $inQuotes = -not $inQuotes
                    $index++
                }
                $started = $true
                continue
            }

            [void] $builder.Append($character)
            $started = $true
            $index++
        }

        if ($inQuotes) {
            return [PSCustomObject] @{ Success = $false; Tokens = @(); Reason = 'The command contains an unmatched quote.' }
        }
        if ($started) { $tokens.Add($builder.ToString()) }
    }

    if ($tokens.Count -eq 0) {
        return [PSCustomObject] @{ Success = $false; Tokens = @(); Reason = 'The command contains no executable token.' }
    }
    return [PSCustomObject] @{ Success = $true; Tokens = $tokens.ToArray(); Reason = $null }
}


function Test-ForgeStringArrayEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string[]] $Left,
        [Parameter(Mandatory)] [string[]] $Right
    )

    if ($Left.Count -ne $Right.Count) { return $false }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if (-not [string]::Equals($Left[$index], $Right[$index], [StringComparison]::Ordinal)) { return $false }
    }
    return $true
}


function ConvertTo-ForgeDiscoveredCommand {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CommandLine
    )

    $parsed = Split-ForgeWindowsCommandLine -CommandLine $CommandLine
    if (-not $parsed.Success) {
        return [PSCustomObject] @{ Success = $false; Command = $null; Reason = $parsed.Reason }
    }

    $executable = $parsed.Tokens[0]
    if ($executable -notmatch '(?i)\.(exe|com|cmd|bat)$') {
        return [PSCustomObject] @{
            Success = $false
            Command = $null
            Reason  = "The first token '$executable' is not an explicit executable. An unquoted path containing spaces may be ambiguous."
        }
    }
    if ($executable -match '(^|\\)\.\.(\\|$)') {
        return [PSCustomObject] @{ Success = $false; Command = $null; Reason = 'The executable path is not a safe, portable path.' }
    }

    $arguments = if ($parsed.Tokens.Count -gt 1) { @($parsed.Tokens[1..($parsed.Tokens.Count - 1)]) } else { @() }
    $command = [CommandSpec]::new($executable, $arguments, @(0))
    $roundTrip = Split-ForgeWindowsCommandLine -CommandLine (ConvertTo-CommandString -CommandSpec $command)
    if (-not $roundTrip.Success -or -not (Test-ForgeStringArrayEqual -Left $parsed.Tokens -Right $roundTrip.Tokens)) {
        return [PSCustomObject] @{ Success = $false; Command = $null; Reason = 'The command could not be round-tripped without changing its argument tokens.' }
    }

    return [PSCustomObject] @{ Success = $true; Command = $command.ToOrderedDictionary(); Reason = $null }
}


function Get-ForgeDisplayIconPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DisplayIcon
    )

    $value = $DisplayIcon.Trim()
    if ($value -match '^"(?<Path>[^"]+)"(?:\s*,\s*-?\d+)?$') { return $Matches['Path'] }
    if ($value -match '^(?<Path>.+?\.exe)(?:\s*,\s*-?\d+)?$') { return $Matches['Path'].Trim() }
    return $null
}


function Test-ForgeDetectionTarget {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $InstallLocation
    )

    if ($Path -notmatch '(?i)\.exe$' -or $Path -match '(^|\\)\.\.(\\|$)') { return $false }
    $fileName = [System.IO.Path]::GetFileName($Path)
    if ($fileName -match '(?i)^(unins|uninstall|setup|install|update|maintenance).*\.exe$') { return $false }

    $root = $InstallLocation.TrimEnd([char] 92)
    if (-not $Path.StartsWith(($root + [char] 92), [StringComparison]::OrdinalIgnoreCase)) { return $false }

    return Test-Path -LiteralPath (Expand-ForgePortablePath -Value $Path) -PathType Leaf
}


function ConvertTo-InstalledAppMatch {
    <# Converts one sanitized uninstall-registry row into evidence and findings. #>
    [CmdletBinding()]
    [OutputType('PSPackageForge.InstalledAppMatch')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNull()]
        [object] $Entry
    )

    process {
        foreach ($requiredProperty in @('Hive', 'View', 'SubKey', 'DisplayName')) {
            if ($null -eq $Entry.PSObject.Properties[$requiredProperty]) {
                throw [System.ArgumentException]::new("Installed-app entry is missing required property '$requiredProperty'.", 'Entry')
            }
        }

        $evidence = [System.Collections.Generic.List[EvidenceRecord]]::new()
        $findings = [System.Collections.Generic.List[Finding]]::new()
        $addEvidence = {
            param([string] $field, [object] $value, [ConfidenceLevel] $confidence, [string] $notes)
            if ($null -eq $value) { return }
            if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { return }
            $evidence.Add([EvidenceRecord]::new($field, $value, [EvidenceSource]::Registry, $confidence, $notes))
        }

        $displayName = [string] $Entry.DisplayName
        & $addEvidence 'ProductName' $displayName ([ConfidenceLevel]::High) 'DisplayName from the Windows uninstall registry.'
        & $addEvidence 'Manufacturer' $Entry.Publisher ([ConfidenceLevel]::High) 'Publisher from the Windows uninstall registry.'
        & $addEvidence 'ProductVersionRaw' $Entry.DisplayVersion ([ConfidenceLevel]::High) 'DisplayVersion exactly as registered; not normalized.'

        $missingIdentity = @()
        if ([string]::IsNullOrWhiteSpace($displayName)) { $missingIdentity += 'DisplayName' }
        if ([string]::IsNullOrWhiteSpace([string] $Entry.Publisher)) { $missingIdentity += 'Publisher' }
        if ([string]::IsNullOrWhiteSpace([string] $Entry.DisplayVersion)) { $missingIdentity += 'DisplayVersion' }
        if ($missingIdentity.Count -gt 0) {
            $findings.Add((New-ForgeFinding -Severity Info -Code 'INSTALLED_APP_IDENTITY_INCOMPLETE' -Field 'ProductName' -Message (
                'The uninstall registration does not contain: {0}. No replacement value was inferred.' -f ($missingIdentity -join ', '))))
        }

        if (-not [string]::IsNullOrWhiteSpace([string] $Entry.InstallLocation)) {
            & $addEvidence 'InstallLocation' $Entry.InstallLocation ([ConfidenceLevel]::High) 'InstallLocation directly observed in the Windows uninstall registry.'
        }
        else {
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'INSTALLED_APP_INSTALL_LOCATION_UNRESOLVED' -Field 'InstallLocation' -Message (
                'The uninstall registration has no portable InstallLocation. No location was inferred from the uninstall command.')))
        }

        $context = if ($Entry.Hive -eq 'LocalMachine') { 'System' } else { 'User' }
        & $addEvidence 'SelectedContext' $context ([ConfidenceLevel]::High) "Registration was observed under the $($Entry.Hive) hive."
        if ($Entry.Hive -eq 'LocalMachine') {
            $architecture = if ($Entry.View -eq 'Registry64') { 'x64' } else { 'x86' }
            & $addEvidence 'Architecture' $architecture ([ConfidenceLevel]::Medium) (
                "The product registered in the $($Entry.View) uninstall view. Registry view is not proof of payload architecture.")
        }
        else {
            $findings.Add((New-ForgeFinding -Severity Info -Code 'INSTALLED_APP_ARCHITECTURE_UNRESOLVED' -Field 'Architecture' -Message (
                'A current-user uninstall registration does not determine payload architecture. No architecture was inferred.')))
        }

        Add-ForgeInstalledAppUninstallEvidence -Entry $Entry -Findings $findings -AddEvidence $addEvidence
        Add-ForgeInstalledAppDetectionEvidence -Entry $Entry -Findings $findings -AddEvidence $addEvidence

        $merge = Merge-InstallerEvidence -Evidence $evidence.ToArray()
        foreach ($finding in $merge.Findings) { $findings.Add($finding) }

        $matchId = Get-InstalledAppMatchId -Hive $Entry.Hive -View $Entry.View -SubKey $Entry.SubKey

        return [PSCustomObject] [ordered] @{
            PSTypeName       = 'PSPackageForge.InstalledAppMatch'
            MatchId          = $matchId
            DisplayName      = $displayName
            RegistryIdentity = [ordered] @{
                Hive = [string] $Entry.Hive; View = [string] $Entry.View; SubKey = [string] $Entry.SubKey
            }
            Evidence         = $evidence.ToArray()
            ResolvedEvidence = @($merge.Resolved.Values)
            Findings         = $findings.ToArray()
        }
    }
}

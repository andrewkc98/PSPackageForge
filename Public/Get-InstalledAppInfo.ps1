function Get-InstalledAppInfo {
    <#
        .SYNOPSIS
            Discovers installed-application evidence from the Windows uninstall registry.

        .DESCRIPTION
            Run this command on a reference machine where the application is installed.
            It enumerates both machine registry views plus the current user's uninstall
            registry, returns one independent match per registration, and optionally writes
            versioned discovery JSON for New-PackageScaffold -DiscoveryData.

            Registry values are observations, not permission to guess. Missing or ambiguous
            commands, locations, and detection targets become Findings. No match is selected
            implicitly and unrelated registrations are never merged.

        .PARAMETER DisplayNameLike
            PowerShell wildcard pattern matched against non-empty DisplayName values.

        .PARAMETER OutputPath
            Optional path for schema-versioned discovery JSON. The in-memory result is
            returned whether or not a document is written.

        .EXAMPLE
            Get-InstalledAppInfo -DisplayNameLike 'KiCad*' -OutputPath .\KiCad.discovery.json

        .OUTPUTS
            PSPackageForge.InstalledAppDiscoveryResult
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('PSPackageForge.InstalledAppDiscoveryResult')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DisplayNameLike,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath
    )

    $findings = [System.Collections.Generic.List[Finding]]::new()
    $entries  = [System.Collections.Generic.List[object]]::new()

    $targets = [System.Collections.Generic.List[object]]::new()
    if ([Environment]::Is64BitOperatingSystem) {
        $targets.Add([PSCustomObject] @{ Hive = 'LocalMachine'; View = 'Registry64' })
        $targets.Add([PSCustomObject] @{ Hive = 'LocalMachine'; View = 'Registry32' })
        # HKCU's normal Software tree is shared across WOW64 views. Read it once using the
        # OS-native view or the same registrations would be returned twice.
        $targets.Add([PSCustomObject] @{ Hive = 'CurrentUser'; View = 'Registry64' })
    }
    else {
        $targets.Add([PSCustomObject] @{ Hive = 'LocalMachine'; View = 'Registry32' })
        $targets.Add([PSCustomObject] @{ Hive = 'CurrentUser'; View = 'Registry32' })
    }

    foreach ($target in $targets) {
        try {
            foreach ($entry in @(Get-RegistryUninstallEntry -Hive $target.Hive -View $target.View)) {
                if ($null -eq $entry) { continue }
                if ($entry.PSObject.Properties.Match('ReadError').Count -gt 0 -and $entry.ReadError) {
                    $findings.Add((New-ForgeFinding -Severity Warning -Code 'INSTALLED_APP_ENTRY_READ_FAILED' -Message (
                        "The uninstall registry entry '{0}' in {1} {2} could not be read. Other entries in that view were still inspected." -f
                            $entry.SubKey, $entry.Hive, $entry.View)))
                    continue
                }
                $entries.Add($entry)
            }
        }
        catch {
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'INSTALLED_APP_REGISTRY_READ_FAILED' -Message (
                "The {0} {1} uninstall registry could not be read: {2}. Other registry scopes were still inspected." -f
                    $target.Hive, $target.View, $_.Exception.Message)))
        }
    }

    $matchingEntries = @(
        $entries |
            Where-Object {
                -not [bool] $_.SystemComponent -and
                -not [string]::IsNullOrWhiteSpace("$($_.DisplayName)") -and
                "$($_.DisplayName)" -like $DisplayNameLike
            } |
            Sort-Object -Property DisplayName, Hive, View, SubKey
    )

    $discoveredMatches = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $matchingEntries) {
        try {
            $discoveredMatches.Add((ConvertTo-InstalledAppMatch -Entry $entry))
        }
        catch {
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'INSTALLED_APP_ENTRY_READ_FAILED' -Field 'ProductName' -Message (
                "The registry entry for '{0}' could not be converted into evidence: {1}" -f
                    $entry.DisplayName, $_.Exception.Message)))
        }
    }

    if ($discoveredMatches.Count -eq 0) {
        $findings.Add((New-ForgeFinding -Severity Warning -Code 'INSTALLED_APP_NOT_FOUND' -Field 'ProductName' -Message (
            "No visible uninstall registry entry matched DisplayName pattern '$DisplayNameLike'. No application evidence was invented.")))
    }

    $result = [PSCustomObject] @{
        PSTypeName      = 'PSPackageForge.InstalledAppDiscoveryResult'
        SchemaVersion  = "$script:DiscoverySchemaVersion"
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Query           = [ordered] @{ DisplayNameLike = $DisplayNameLike }
        Matches         = $discoveredMatches.ToArray()
        Findings        = $findings.ToArray()
        DiscoveryPath   = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputPath) -and
        $PSCmdlet.ShouldProcess($OutputPath, 'Write installed-application discovery JSON')) {
        $parent = Split-Path -Path $OutputPath -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            [void] (New-Item -ItemType Directory -Path $parent -Force)
        }

        $document = ConvertTo-InstalledAppDiscoveryDocument -Discovery $result
        $json = $document | ConvertTo-Json -Depth 20
        Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8

        # Structural validation proves the emitted artifact is readable JSON before it is
        # handed to another machine. Semantic validation happens on import as well.
        $null = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $result.DiscoveryPath = (Resolve-Path -LiteralPath $OutputPath).ProviderPath
    }

    return $result
}

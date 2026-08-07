#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [switch] $AllowNoMatches
    )

    $output = @(& git @ArgumentList 2>$null)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not ($AllowNoMatches -and $exitCode -eq 1)) {
        throw "git $($ArgumentList -join ' ') failed with exit code $exitCode."
    }

    return $output
}

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).ProviderPath
Push-Location $repositoryRoot

try {
    $failures = [System.Collections.Generic.List[string]]::new()

    # rev-list --objects walks every object reachable from every local ref, including files
    # that were subsequently deleted. git ls-files only checks the current tree.
    $objects = Invoke-GitCommand -ArgumentList @('rev-list', '--objects', '--all')
    foreach ($line in $objects) {
        if ($line -notmatch '^(?<Object>[0-9a-f]+) (?<Path>.+)$') { continue }

        $objectId = $Matches.Object
        $path     = $Matches.Path -replace '\\', '/'
        $allowedFixture = $path -match '^Tests/Fixtures/(native-clean\.msi|wrapper-style\.msi|dummy\.exe|framework-stubs/[^/]+\.exe)$'
        if ($path -match '(?i)\.(msi|exe|msix|appx|intunewin)$' -and -not $allowedFixture) {
            $failures.Add("Vendor installer binary in history: object $objectId, path $path")
        }
    }

    $commits = Invoke-GitCommand -ArgumentList @('rev-list', '--all')
    $contentPatterns = @(
        @{ Name = 'internal domain'; Pattern = '\b[A-Za-z0-9-]+\.(local|corp|internal|lan)\b' }
        @{ Name = 'hardcoded user profile'; Pattern = '[A-Za-z]:\\Users\\[A-Za-z0-9._-]+' }
    )

    foreach ($commit in $commits) {
        foreach ($rule in $contentPatterns) {
            $grepResults = Invoke-GitCommand -ArgumentList @(
                'grep', '-I', '-n', '-E', $rule.Pattern, $commit, '--'
            ) -AllowNoMatches

            foreach ($match in $grepResults) {
                # CONTOSO values are the documented repository-safe placeholders.
                if ($rule.Name -eq 'internal domain' -and $match -match '(?i)contoso') { continue }
                if ($rule.Name -eq 'hardcoded user profile' -and
                    $match -match '(?i)[A-Z]:\\Users\\(\.\.\.|Public\\|Default\\|\[|<|%|\$)') { continue }
                $failures.Add("$($rule.Name) in history: $match")
            }
        }
    }

    if ($failures.Count -gt 0) {
        $failures | Sort-Object -Unique | ForEach-Object { Write-Error $_ -ErrorAction Continue }
        exit 1
    }

    Write-Host "Git history opsec scan passed across $($commits.Count) reachable commit(s)."
}
finally {
    Pop-Location
}

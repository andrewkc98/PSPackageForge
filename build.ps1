#Requires -Version 5.1
<#
    .SYNOPSIS
        Local and CI entry point. CI runs exactly this script, so a green badge means the
        same checks a developer can run on their own machine passed.

    .PARAMETER Task
        Analyze -- PSScriptAnalyzer, warnings treated as errors.
        Test    -- Pester 5 suite.
        All     -- both (default).

    .EXAMPLE
        .\build.ps1
        .\build.ps1 -Task Test -Output Detailed
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Analyze', 'Test')]
    [string] $Task = 'All',

    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string] $Output = 'Normal',

    # Emit NUnit XML for CI test reporting.
    [string] $TestResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

# Pinned so CI dependencies cannot drift underneath the suite (plan §11).
$PesterVersion   = '5.7.1'
$AnalyzerVersion = '1.25.0'

Write-Host "PSPackageForge build -- $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)" -ForegroundColor Cyan


if ($Task -in @('All', 'Analyze')) {
    Write-Host "`n=== PSScriptAnalyzer ===" -ForegroundColor Cyan

    Import-Module PSScriptAnalyzer -RequiredVersion $AnalyzerVersion -Force

    $results = Invoke-ScriptAnalyzer -Path $root -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1')

    # Generated output under Examples/ is a rendering artefact, not module source.
    $results = @($results | Where-Object { $_.ScriptPath -notmatch '\\Examples\\' })

    if ($results.Count -gt 0) {
        # Not every diagnostic record carries an Extent -- file-level rules such as
        # PSUseBOMForUnicodeEncodedFile report against the file, not a line -- so Line has
        # to be read defensively rather than assumed.
        $results |
            Select-Object -Property Severity, ScriptName, RuleName, Message,
                @{ Name = 'Line'; Expression = {
                        if ($_.PSObject.Properties['Extent'] -and $_.Extent) { $_.Extent.StartLineNumber } else { 0 }
                    } } |
            Sort-Object -Property Severity, ScriptName, Line |
            Format-Table -AutoSize -Property Severity, ScriptName, Line, RuleName, Message |
            Out-String -Width 200 |
            Write-Host

        # Warnings as errors: a style rule nobody enforces is a style rule nobody follows.
        $failures.Add("PSScriptAnalyzer reported $($results.Count) issue(s).")
    }
    else {
        Write-Host 'PSScriptAnalyzer clean.' -ForegroundColor Green
    }
}


if ($Task -in @('All', 'Test')) {
    Write-Host "`n=== Pester ===" -ForegroundColor Cyan

    Import-Module Pester -RequiredVersion $PesterVersion -Force

    $config = New-PesterConfiguration
    $config.Run.Path        = Join-Path $root 'Tests'
    $config.Run.PassThru    = $true
    $config.Output.Verbosity = $Output

    if ($TestResultPath) {
        $config.TestResult.Enabled      = $true
        $config.TestResult.OutputPath   = $TestResultPath
        $config.TestResult.OutputFormat = 'NUnitXml'
    }

    $result = Invoke-Pester -Configuration $config

    if ($result.FailedCount -gt 0) {
        $failures.Add("Pester reported $($result.FailedCount) failed test(s).")
    }
}


Write-Host ''
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) { Write-Host "FAILED: $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'Build succeeded.' -ForegroundColor Green
exit 0

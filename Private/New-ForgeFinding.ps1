function New-ForgeFinding {
    <#
        .SYNOPSIS
            Creates a Finding.

        .DESCRIPTION
            Findings replace the flat Warnings[] of earlier drafts (plan §5.1). Every
            finding carries a short stable Code so tests and generated documentation can
            refer to a condition without matching on message text -- message wording is
            allowed to improve, codes are not allowed to drift.

            Severity is load-bearing, not decorative:

              Blocking -- a critical decision could not be resolved. Forces
                          Readiness = NeedsInput and suppresses runnable output (plan §5.5).
              Warning  -- the scaffold is usable but a human must check this before deploying.
              Info     -- context worth recording; no action implied.

        .EXAMPLE
            New-ForgeFinding -Severity Blocking -Code FRAMEWORK_AMBIGUOUS -Message 'Multiple installer frameworks matched.' -Field Framework
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructs an in-memory object. It changes no state and touches nothing on disk, so -WhatIf would be noise.')]
    [CmdletBinding()]
    [OutputType([Finding])]
    param(
        [Parameter(Mandatory)]
        [FindingSeverity] $Severity,

        # Short, stable, SCREAMING_SNAKE_CASE identifier, e.g. EVIDENCE_CONFLICT.
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z][A-Z0-9_]*$')]
        [string] $Code,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Message,

        # The affected field, when the finding is about one specific field.
        [Parameter()]
        [string] $Field
    )

    if ([string]::IsNullOrWhiteSpace($Field)) {
        return [Finding]::new($Severity, $Code, $Message)
    }

    return [Finding]::new($Severity, $Code, $Message, $Field)
}

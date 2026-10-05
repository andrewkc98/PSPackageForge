function Get-DocumentOptionalProperty {
    <#
        .SYNOPSIS
            Safely reads a property that a manifest ToOrderedDictionary() method only emits
            conditionally (Notes, Field, Rationale, ...).

        .DESCRIPTION
            ConvertFrom-Json produces a PSCustomObject with no property at all when the
            source JSON omitted a key. Under Set-StrictMode -Version Latest, referencing a
            missing property throws PropertyNotFoundException, so every conditionally-emitted
            manifest field must be read through this helper instead of dotted access.

        This definition is intentionally neutral: it lives at the Private root so the document
        renderer and validation can share it without the document renderer owning it.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject.PSObject.Properties.Match($Name).Count -eq 0) { return $null }
    return $InputObject.$Name
}

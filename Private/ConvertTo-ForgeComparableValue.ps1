function ConvertTo-ForgeComparableValue {
    <#
        .SYNOPSIS
            Reduces an evidence value to a canonical string used only for equality testing.

        .DESCRIPTION
            The merger needs to answer one question: do two sources agree? That is harder
            than -eq, because the same fact arrives in different shapes -- an MSI reports
            a ProductCode as {B67274A8-...}, a registry key name reports the same GUID in
            a different case, and a path may or may not carry a trailing separator.

            The output of this function is NEVER stored, rendered, or compared against
            anything a user sees. It exists so that a cosmetic difference does not get
            reported as an EVIDENCE_CONFLICT, and so that a genuine difference does.

            Deliberately NOT normalised here:
              * Version strings. '1.0' and '1.0.0.0' are different facts; collapsing them
                would hide exactly the padding question plan §7.3 says to surface.
              * Environment variable expansion. %LOCALAPPDATA%\Obsidian and a resolved
                C:\Users\...\Obsidian genuinely disagree about install context.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [object] $Value
    )

    if ($null -eq $Value) { return '<null>' }

    # Arrays compare element-wise, in order. Order matters for an ArgumentList.
    if ($Value -is [System.Array]) {
        $parts = foreach ($item in $Value) { ConvertTo-ForgeComparableValue -Value $item }
        return '<array>[' + ($parts -join '|') + ']'
    }

    if ($Value -is [bool]) {
        return ([bool] $Value).ToString().ToLowerInvariant()
    }

    if ($Value -is [System.Enum]) {
        return $Value.ToString().ToLowerInvariant()
    }

    if ($Value -is [string]) {
        $text = ([string] $Value).Trim()
        if ($text.Length -eq 0) { return '<empty>' }

        # A GUID is the same GUID whatever the bracket and case convention.
        $guid = [guid]::Empty
        if ([guid]::TryParse($text.Trim('{', '}'), [ref] $guid)) {
            return $guid.ToString('B').ToLowerInvariant()
        }

        # Collapse a trailing path separator only; nothing else about the path is touched.
        if ($text.Length -gt 1) { $text = $text.TrimEnd('\', '/') }

        return $text.ToLowerInvariant()
    }

    return [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value).Trim().ToLowerInvariant()
}

function Get-ForgeEnumValue {
    <#
        .SYNOPSIS
            Converts an evidence value to an enum member, falling back rather than throwing.

        .DESCRIPTION
            Evidence values are stored as strings so the manifest round-trips identically on
            Windows PowerShell 5.1 and PowerShell 7 (both serialise enums as integers
            otherwise, and the manifest is meant to be read by humans).

            Converting them back has to be forgiving in a specific way: an unrecognised value
            must produce the supplied default, not an exception. Evidence can come from a
            user override or a discovery file written by a different version of the tool, and
            a scaffolder that dies on an unexpected string is worse than one that falls back
            to Unknown and reports it.

        .EXAMPLE
            Get-ForgeEnumValue -Value 'x64' -Type ([ArchitectureType]) -Default ([ArchitectureType]::Unknown)
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Value,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [type] $Type,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Default
    )

    if ($null -eq $Value) { return $Default }

    # Already the right enum type: pass it through untouched.
    if ($Value.GetType() -eq $Type) { return $Value }

    $text = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    foreach ($name in [enum]::GetNames($Type)) {
        if ($name -eq $text) { return [enum]::Parse($Type, $name) }
    }

    Write-Verbose "'$text' is not a member of $($Type.Name); using default '$Default'."
    return $Default
}

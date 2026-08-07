function ConvertTo-ForgeDisplayValue {
    <#
        .SYNOPSIS
            Renders an evidence value for a human-readable finding message.

        .DESCRIPTION
            Unlike ConvertTo-ForgeComparableValue, this preserves the value as the provider
            actually reported it -- case, brackets, padding and all. A finding that says
            two sources disagree has to show what each one really said, or the operator
            cannot tell which is right.
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

    if ($null -eq $Value) { return '(null)' }

    if ($Value -is [System.Array]) {
        $parts = foreach ($item in $Value) { ConvertTo-ForgeDisplayValue -Value $item }
        return ($parts -join ' ')
    }

    if ($Value -is [bool]) { return ([bool] $Value).ToString() }

    $text = [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value)
    if ([string]::IsNullOrWhiteSpace($text)) { return '(empty)' }

    return $text
}

function ConvertTo-WindowsCommandLineToken {
    <#
        Implements the Windows CommandLineToArgvW/CRT quoting convention. Backslashes only
        need special handling when they precede a quote or the closing quote.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $builder     = [System.Text.StringBuilder]::new()
    $backslashes = 0
    [void] $builder.Append('"')

    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char] 92) {
            $backslashes++
            continue
        }

        if ($character -eq [char] 34) {
            if ($backslashes -gt 0) { [void] $builder.Append([char] 92, ($backslashes * 2)) }
            [void] $builder.Append([char] 92)
            [void] $builder.Append([char] 34)
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void] $builder.Append([char] 92, $backslashes)
            $backslashes = 0
        }
        [void] $builder.Append($character)
    }

    if ($backslashes -gt 0) { [void] $builder.Append([char] 92, ($backslashes * 2)) }
    [void] $builder.Append('"')
    return $builder.ToString()
}


function ConvertTo-CommandString {
    <#
        .SYNOPSIS
            The single boundary where a CommandSpec becomes a Windows command line.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [CommandSpec] $CommandSpec
    )

    process {
        if (-not $CommandSpec.IsResolved()) {
            throw [System.InvalidOperationException]::new('Cannot render an unresolved CommandSpec.')
        }

        $tokens = [System.Collections.Generic.List[string]]::new()
        $tokens.Add((ConvertTo-WindowsCommandLineToken -Value $CommandSpec.Executable))
        foreach ($argument in $CommandSpec.ArgumentList) {
            $tokens.Add((ConvertTo-WindowsCommandLineToken -Value $(if ($null -eq $argument) { '' } else { $argument })))
        }

        return ($tokens -join ' ')
    }
}

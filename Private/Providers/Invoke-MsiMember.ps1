<#
    Low-level WindowsInstaller COM plumbing.

    The WindowsInstaller.Installer object is a late-bound IDispatch COM object. In Windows
    PowerShell 5.1 the usual $object.Method() syntax against it is unreliable -- depending on
    whether an interop assembly happens to be loaded, calls either bind to the wrong overload
    or fail outright with "Unknown name". Reflection via InvokeMember is the form that works
    the same way on 5.1 and on PowerShell 7, which is why every call goes through here.
#>

function Invoke-MsiMember {
    <#
        .SYNOPSIS
            Calls a method or reads a property on a WindowsInstaller COM object.

        .PARAMETER Type
            InvokeMethod for methods (OpenDatabase, OpenView, Execute, Fetch, Close),
            GetProperty for properties (SummaryInformation, StringData, Property).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Target,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('InvokeMethod', 'GetProperty')]
        [string] $Type,

        [Parameter()]
        [AllowNull()]
        [object[]] $Arguments
    )

    $binding = [System.Reflection.BindingFlags] $Type

    return $Target.GetType().InvokeMember($Name, $binding, $null, $Target, $Arguments)
}


function Get-MsiRecordSet {
    <#
        .SYNOPSIS
            Runs an MSI SQL query and emits one string array per row.

        .DESCRIPTION
            Columns are read as StringData, which is correct for every column this module
            reads. Integer columns arrive as their string form and callers convert
            deliberately -- an MSI integer column can legitimately be empty, and letting a
            silent [int] cast turn that into 0 would invent a fact.

            Binary stream columns must NOT be selected through this function; reading a
            stream as StringData throws.

        .PARAMETER ColumnCount
            How many columns the SELECT returns. MSI records are 1-indexed and expose no
            reliable field count through StringData, so the caller states it.
    #>
    [CmdletBinding()]
    [OutputType([System.Array])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Database,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Query,

        [Parameter(Mandatory)]
        [ValidateRange(1, 32)]
        [int] $ColumnCount
    )

    $view = $null

    try {
        $view = Invoke-MsiMember -Target $Database -Name 'OpenView' -Type InvokeMethod -Arguments @($Query)
        $null = Invoke-MsiMember -Target $view -Name 'Execute' -Type InvokeMethod -Arguments $null

        while ($true) {
            $record = Invoke-MsiMember -Target $view -Name 'Fetch' -Type InvokeMethod -Arguments $null
            if ($null -eq $record) { break }

            try {
                $values = New-Object string[] $ColumnCount

                for ($column = 1; $column -le $ColumnCount; $column++) {
                    $values[$column - 1] = Invoke-MsiMember -Target $record -Name 'StringData' -Type GetProperty -Arguments @($column)
                }

                # Comma prevents PowerShell unrolling the row into the pipeline.
                , $values
            }
            finally {
                $null = Remove-ComObject -InputObject $record
            }
        }
    }
    finally {
        if ($view) {
            try {
                $null = Invoke-MsiMember -Target $view -Name 'Close' -Type InvokeMethod -Arguments $null
            }
            catch {
                # A view that is already closed throws here. The release below is what
                # actually matters, so this is noted and not escalated.
                Write-Verbose "Closing MSI view failed (already closed?): $($_.Exception.Message)"
            }

            $null = Remove-ComObject -InputObject $view
        }
    }
}


function Remove-ComObject {
    <#
        .SYNOPSIS
            Releases a runtime callable wrapper, tolerating anything that is not one.

        .DESCRIPTION
            Every COM object this module creates is released explicitly. Windows Installer
            keeps a handle on the .msi until its wrappers are gone, and a leaked handle
            shows up much later as a sharing violation when something tries to copy the
            installer -- a confusing failure to trace back to its cause.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Releases an in-process COM wrapper. It touches no user-visible state, so -WhatIf would be meaningless.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) { return 0 }

    try {
        if ([System.Runtime.InteropServices.Marshal]::IsComObject($InputObject)) {
            return [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($InputObject)
        }
    }
    catch {
        Write-Verbose "Could not release COM object: $($_.Exception.Message)"
    }

    return 0
}

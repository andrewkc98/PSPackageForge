function ConvertTo-PSADTPowerShellStringLiteral {
    <#
        .SYNOPSIS
            Quotes a manifest string as a PowerShell single-quoted literal.

        .DESCRIPTION
            Installer-controlled values are data, never source. Doubling apostrophes is the
            only escape PowerShell single-quoted strings require and prevents a product name,
            executable, or argument from breaking out into generated script code.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return "''" }
    return "'{0}'" -f ("$Value".Replace("'", "''"))
}


function ConvertTo-PSADTStringArrayLiteral {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]] $Value
    )

    $items = @($Value | ForEach-Object { ConvertTo-PSADTPowerShellStringLiteral -Value $_ })
    return '@({0})' -f ($items -join ', ')
}


function ConvertTo-PSADTIntegerArrayLiteral {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [int[]] $Value
    )

    $items = @($Value | ForEach-Object { [string] ([int] $_) })
    return '@({0})' -f ($items -join ', ')
}


function Get-PSADTCommandRenderData {
    <#
        .SYNOPSIS
            Converts one structured manifest command into PSADT process-call data.

        .DESCRIPTION
            Command strings are never parsed. Executable, ArgumentList, and expected return
            codes stay structured until they become PowerShell literals. Every expected code
            must have a success-shaped ReturnCodeMap classification; an unexplained, retry, or
            failure code is rejected instead of being rendered as success.
    #>
    [CmdletBinding()]
    [OutputType('PSPackageForge.PSADTCommandRenderData')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Uninstall')]
        [string] $Operation,

        [Parameter()]
        [AllowNull()]
        [object] $Command,

        [Parameter()]
        [AllowNull()]
        [object[]] $ReturnCodeMap
    )

    $executable = Get-DocumentOptionalProperty -InputObject $Command -Name 'Executable'
    if ($null -eq $Command -or [string]::IsNullOrWhiteSpace("$executable")) {
        throw [System.IO.InvalidDataException]::new(
            "PackageManifest.json does not contain a resolved $Operation command. A runnable PSADT package was not generated.")
    }

    $arguments = @()
    $rawArguments = Get-DocumentOptionalProperty -InputObject $Command -Name 'ArgumentList'
    if ($null -ne $rawArguments) {
        $arguments = @($rawArguments | ForEach-Object { "$_" })
    }

    $rawExpectedExitCodes = Get-DocumentOptionalProperty -InputObject $Command -Name 'ExpectedExitCodes'
    $expectedExitCodes = @($rawExpectedExitCodes | ForEach-Object { [int] $_ })
    if ($expectedExitCodes.Count -eq 0) {
        throw [System.IO.InvalidDataException]::new(
            "The manifest $Operation command has no ExpectedExitCodes. PSPackageForge will not guess which process result means success.")
    }

    $successCodes = [System.Collections.Generic.List[int]]::new()
    $rebootCodes  = [System.Collections.Generic.List[int]]::new()
    $rows = @($ReturnCodeMap)

    foreach ($code in $expectedExitCodes) {
        $matchingRows = @($rows | Where-Object {
                $mappedCode = Get-DocumentOptionalProperty -InputObject $_ -Name 'Code'
                $null -ne $mappedCode -and [int] $mappedCode -eq $code
            })
        if ($matchingRows.Count -ne 1) {
            throw [System.IO.InvalidDataException]::new(
                "Expected exit code $code for the $Operation command does not have exactly one ReturnCodeMap entry.")
        }

        $classification = "$(Get-DocumentOptionalProperty -InputObject $matchingRows[0] -Name 'Classification')"
        switch ($classification) {
            'Success'                { $successCodes.Add($code) }
            'SuccessRebootRequired'  { $rebootCodes.Add($code) }
            'SuccessRebootInitiated' { $rebootCodes.Add($code) }
            default {
                throw [System.IO.InvalidDataException]::new(
                    "Expected exit code $code for the $Operation command is classified as '$classification', not as success or reboot success.")
            }
        }
    }

    [PSCustomObject] @{
        PSTypeName    = 'PSPackageForge.PSADTCommandRenderData'
        Executable    = "$executable"
        ArgumentList  = [string[]] $arguments
        SuccessCodes  = [int[]] @($successCodes)
        RebootCodes   = [int[]] @($rebootCodes)
    }
}


function ConvertTo-PSADTProcessStatement {
    <#
        .SYNOPSIS
            Renders structured command data as a PSADT 4.0.6 Start-ADTProcess call.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $CommandData
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('Start-ADTProcess')
    $parts.Add('-FilePath {0}' -f (ConvertTo-PSADTPowerShellStringLiteral -Value $CommandData.Executable))
    if (@($CommandData.ArgumentList).Count -gt 0) {
        $parts.Add('-ArgumentList {0}' -f (ConvertTo-PSADTStringArrayLiteral -Value $CommandData.ArgumentList))
    }

    # Start-ADTProcess searches Files for a relative executable, while the working directory
    # makes relative payload arguments (for example, `msiexec /i app.msi`) resolve there too.
    $parts.Add('-WorkingDirectory $adtSession.DirFiles')

    if (@($CommandData.SuccessCodes).Count -gt 0) {
        $parts.Add('-SuccessExitCodes {0}' -f (ConvertTo-PSADTIntegerArrayLiteral -Value $CommandData.SuccessCodes))
    }
    if (@($CommandData.RebootCodes).Count -gt 0) {
        # PSADT 4.0.6 validates this parameter with ValidateNotNullOrEmpty, so a legitimate
        # empty manifest set must omit the parameter and fall back to the session-level array.
        $parts.Add('-RebootExitCodes {0}' -f (ConvertTo-PSADTIntegerArrayLiteral -Value $CommandData.RebootCodes))
    }
    return ($parts -join ' ')
}


function ConvertTo-PSADTRenderPlan {
    <#
        .SYNOPSIS
            Produces a pure PSADT rendering plan from a parsed PackageManifest.json.

        .DESCRIPTION
            This function knows nothing about module discovery, New-ADTTemplate, or disk. It
            maps only authoritative manifest fields into session assignments and structured
            process calls suitable for the stable PSADT 4.0.6 v4 frontend markers.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Manifest
    )

    $installer   = Get-DocumentOptionalProperty -InputObject $Manifest -Name 'Installer'
    $packageSpec = Get-DocumentOptionalProperty -InputObject $Manifest -Name 'PackageSpec'
    $productName = Get-DocumentOptionalProperty -InputObject $installer -Name 'ProductName'
    if ([string]::IsNullOrWhiteSpace("$productName")) {
        throw [System.IO.InvalidDataException]::new(
            'PackageManifest.json does not contain Installer.ProductName. A PSADT package identity cannot be rendered.')
    }

    $returnCodeMap = @(Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'ReturnCodeMap')
    $installData = Get-PSADTCommandRenderData -Operation Install `
        -Command (Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'InstallCommand') `
        -ReturnCodeMap $returnCodeMap
    $uninstallData = Get-PSADTCommandRenderData -Operation Uninstall `
        -Command (Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'UninstallCommand') `
        -ReturnCodeMap $returnCodeMap

    $architecture = "$(Get-DocumentOptionalProperty -InputObject $installer -Name 'Architecture')"
    if ($architecture -notin @('x86', 'x64', 'Arm64')) { $architecture = '' }

    $successCodes = [int[]] @(@($installData.SuccessCodes) + @($uninstallData.SuccessCodes) | Sort-Object -Unique)
    $rebootCodes  = [int[]] @(@($installData.RebootCodes) + @($uninstallData.RebootCodes) | Sort-Object -Unique)

    return [ordered] @{
        AppVendorLiteral       = ConvertTo-PSADTPowerShellStringLiteral `
            -Value (Get-DocumentOptionalProperty -InputObject $installer -Name 'Manufacturer')
        AppNameLiteral         = ConvertTo-PSADTPowerShellStringLiteral -Value $productName
        AppVersionLiteral      = ConvertTo-PSADTPowerShellStringLiteral `
            -Value (Get-DocumentOptionalProperty -InputObject $installer -Name 'ProductVersionRaw')
        AppArchLiteral         = ConvertTo-PSADTPowerShellStringLiteral -Value $architecture
        AppSuccessCodesLiteral = ConvertTo-PSADTIntegerArrayLiteral -Value $successCodes
        AppRebootCodesLiteral  = ConvertTo-PSADTIntegerArrayLiteral -Value $rebootCodes
        InstallStatement       = ConvertTo-PSADTProcessStatement -CommandData $installData
        UninstallStatement     = ConvertTo-PSADTProcessStatement -CommandData $uninstallData
    }
}


function ConvertTo-PSADTTemplateAssignmentContent {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Content,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Literal
    )

    $pattern = '(?m)^(?<Indent>[ \t]*){0}[ \t]*=.*$' -f [regex]::Escape($Name)
    $assignmentMatches = [regex]::Matches($Content, $pattern)
    if ($assignmentMatches.Count -ne 1) {
        throw [System.IO.InvalidDataException]::new(
            "The PSADT 4.0.6 frontend did not contain exactly one '$Name' assignment. The pinned template contract may have changed.")
    }

    $assignmentMatch = $assignmentMatches[0]
    $replacement = $assignmentMatch.Groups['Indent'].Value + $Name + ' = ' + $Literal
    return $Content.Remove($assignmentMatch.Index, $assignmentMatch.Length).Insert($assignmentMatch.Index, $replacement)
}


function Add-PSADTTemplateTask {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Content,

        [Parameter(Mandatory)]
        [string] $Marker,

        [Parameter(Mandatory)]
        [string] $Statement
    )

    if ([regex]::Matches($Content, [regex]::Escape($Marker)).Count -ne 1) {
        throw [System.IO.InvalidDataException]::new(
            "The PSADT 4.0.6 frontend did not contain exactly one '$Marker' marker. The pinned template contract may have changed.")
    }

    $newLine = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    return $Content.Replace($Marker, $Marker + $newLine + '    ' + $Statement)
}


function ConvertTo-PSADTTemplateContent {
    <#
        .SYNOPSIS
            Applies a pure render plan to the native PSADT 4.0.6 v4 frontend.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $TemplateContent,

        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [System.Collections.IDictionary] $RenderPlan
    )

    $content = $TemplateContent
    foreach ($assignment in @(
            @{ Name = 'AppVendor';           Literal = $RenderPlan.AppVendorLiteral },
            @{ Name = 'AppName';             Literal = $RenderPlan.AppNameLiteral },
            @{ Name = 'AppVersion';          Literal = $RenderPlan.AppVersionLiteral },
            @{ Name = 'AppArch';             Literal = $RenderPlan.AppArchLiteral },
            @{ Name = 'AppSuccessExitCodes'; Literal = $RenderPlan.AppSuccessCodesLiteral },
            @{ Name = 'AppRebootExitCodes';  Literal = $RenderPlan.AppRebootCodesLiteral }
        )) {
        $content = ConvertTo-PSADTTemplateAssignmentContent -Content $content `
            -Name $assignment.Name -Literal $assignment.Literal
    }

    $content = Add-PSADTTemplateTask -Content $content `
        -Marker '## <Perform Installation tasks here>' -Statement $RenderPlan.InstallStatement
    $content = Add-PSADTTemplateTask -Content $content `
        -Marker '## <Perform Uninstallation tasks here>' -Statement $RenderPlan.UninstallStatement
    return $content
}

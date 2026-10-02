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

    $workingDirectory = Get-DocumentOptionalProperty -InputObject $Command -Name 'WorkingDirectory'
    if ($null -ne $workingDirectory) { $workingDirectory = "$workingDirectory" }

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
        WorkingDirectory = $workingDirectory
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
    $parts.Add('Invoke-PSPFStartADTProcess')
    $parts.Add('-Executable {0}' -f (ConvertTo-PSADTPowerShellStringLiteral -Value $CommandData.Executable))
    $parts.Add('-ArgumentList {0}' -f (ConvertTo-PSADTStringArrayLiteral -Value $CommandData.ArgumentList))
    $parts.Add('-WorkingDirectory {0}' -f (ConvertTo-PSADTPowerShellStringLiteral -Value $CommandData.WorkingDirectory))

    $successCodes = @($CommandData.SuccessCodes)
    if ($successCodes.Count -eq 0) { $successCodes = @(-2147483648) }
    $rebootCodes = @($CommandData.RebootCodes)
    if ($rebootCodes.Count -eq 0) { $rebootCodes = @(-2147483648) }

    $parts.Add('-SuccessExitCodes {0}' -f (ConvertTo-PSADTIntegerArrayLiteral -Value $successCodes))
    $parts.Add('-RebootExitCodes {0}' -f (ConvertTo-PSADTIntegerArrayLiteral -Value $rebootCodes))
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

    $architecture = "$(Get-DocumentOptionalProperty -InputObject $installer -Name 'ApplicationArchitecture')"
    $architectureEvidence = @(
        Get-DocumentOptionalProperty -InputObject $installer -Name 'ResolvedEvidence' |
            Where-Object { "$(Get-DocumentOptionalProperty -InputObject $_ -Name 'Field')" -eq 'ApplicationArchitecture' }
    )
    $architectureConfidence = if ($architectureEvidence.Count -gt 0) {
        "$(Get-DocumentOptionalProperty -InputObject $architectureEvidence[0] -Name 'Confidence')"
    }
    else { '' }
    if ($architecture -notin @('x86', 'x64', 'Arm64', 'Unknown') -or
        $architecture -eq 'Unknown' -or $architectureConfidence -eq 'Low') { $architecture = '' }

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


function Add-PSPFProcessHelper {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Content
    )

    $markerPattern = '(?m)^(?<Indent>[ \t]*)function Install-ADTDeployment[ \t]*\r?$'
    $markerMatches = [regex]::Matches($Content, $markerPattern)
    if ($markerMatches.Count -ne 1) {
        throw [System.IO.InvalidDataException]::new(
            "The PSADT 4.0.6 frontend did not contain exactly one 'function Install-ADTDeployment' marker. The pinned template contract may have changed.")
    }

    $helper = @'
function Invoke-PSPFStartADTProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Executable,
        [Parameter()] [AllowEmptyCollection()] [AllowNull()] [string[]] $ArgumentList,
        [Parameter()] [AllowEmptyString()] [AllowNull()] [string] $WorkingDirectory,
        [Parameter()] [int[]] $SuccessExitCodes,
        [Parameter()] [int[]] $RebootExitCodes
    )

    $expand = {
        param([AllowNull()] [string] $Value)
        if ($null -eq $Value) { return $null }
        return [Environment]::ExpandEnvironmentVariables($Value)
    }
    $quote = {
        param([AllowEmptyString()] [string] $Value)
        if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
        $builder = [Text.StringBuilder]::new()
        $backslashes = 0
        [void] $builder.Append('"')
        foreach ($character in $Value.ToCharArray()) {
            if ($character -eq [char] 92) { $backslashes++; continue }
            if ($character -eq [char] 34) {
                if ($backslashes -gt 0) { [void] $builder.Append([char] 92, ($backslashes * 2)) }
                [void] $builder.Append([char] 92)
                [void] $builder.Append([char] 34)
                $backslashes = 0
                continue
            }
            if ($backslashes -gt 0) { [void] $builder.Append([char] 92, $backslashes); $backslashes = 0 }
            [void] $builder.Append($character)
        }
        if ($backslashes -gt 0) { [void] $builder.Append([char] 92, ($backslashes * 2)) }
        [void] $builder.Append('"')
        return $builder.ToString()
    }

    $expandedExecutable = & $expand $Executable
    $expandedArguments = @($ArgumentList | ForEach-Object { & $expand $_ })
    $argumentString = (@($expandedArguments | ForEach-Object { & $quote $_ }) -join ' ')
    $expandedWorkingDirectory = & $expand $WorkingDirectory
    if ([string]::IsNullOrWhiteSpace($expandedWorkingDirectory)) {
        $resolvedWorkingDirectory = $adtSession.DirFiles
    }
    elseif ($expandedWorkingDirectory -match '^(?:[A-Za-z]:[\\/]|\\\\)') {
        $resolvedWorkingDirectory = $expandedWorkingDirectory
    }
    else {
        $resolvedWorkingDirectory = Join-Path -Path $adtSession.DirFiles -ChildPath $expandedWorkingDirectory
    }

    $invoke = @{
        FilePath = $expandedExecutable
        ArgumentList = $argumentString
        WorkingDirectory = $resolvedWorkingDirectory
    }
    if ($null -ne $SuccessExitCodes -and @($SuccessExitCodes).Count -gt 0) { $invoke.SuccessExitCodes = $SuccessExitCodes }
    if ($null -ne $RebootExitCodes -and @($RebootExitCodes).Count -gt 0) { $invoke.RebootExitCodes = $RebootExitCodes }
    Start-ADTProcess @invoke
}
'@
    $newLine = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $helper = $helper -replace "`r?`n", $newLine
    $match = $markerMatches[0]
    return $Content.Insert($match.Index, $helper + $newLine + $newLine)
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
    $content = Add-PSPFProcessHelper -Content $content
    return $content
}

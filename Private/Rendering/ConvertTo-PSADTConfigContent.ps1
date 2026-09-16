function ConvertTo-PSADTConfigContent {
    <#
        Validates and, for a user-context package, minimally patches a PSADT config.psd1.
        The source is treated as text: values are changed through AST extents so comments,
        formatting, and unrelated keys remain byte-for-byte intact.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ConfigContent,

        [Parameter(Mandatory)]
        [ValidateSet('System', 'User')]
        [string] $SelectedContext
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $ConfigContent,
        [ref] $tokens,
        [ref] $parseErrors)

    if ($parseErrors.Count -ne 0) {
        throw 'PSADT config content contains PowerShell parse errors.'
    }

    $statements = @($ast.EndBlock.Statements)
    $beginStatements = @()
    $processStatements = @()
    if ($null -ne $ast.BeginBlock) { $beginStatements = @($ast.BeginBlock.Statements) }
    if ($null -ne $ast.ProcessBlock) { $processStatements = @($ast.ProcessBlock.Statements) }
    if ($null -ne $ast.ParamBlock -or
        $beginStatements.Count -ne 0 -or
        $processStatements.Count -ne 0 -or
        $statements.Count -ne 1 -or
        $statements[0] -isnot [System.Management.Automation.Language.PipelineAst]) {
        throw 'PSADT config content must contain exactly one root hashtable.'
    }

    $rootPipeline = $statements[0]
    $rootElements = @($rootPipeline.PipelineElements)
    if ($rootElements.Count -ne 1 -or
        $rootElements[0].Expression -isnot [System.Management.Automation.Language.HashtableAst]) {
        throw 'PSADT config content must contain exactly one root hashtable.'
    }

    $root = $rootElements[0].Expression
    $sectionEntries = @{}
    foreach ($pair in $root.KeyValuePairs) {
        $keyAst = $pair.Item1
        if ($keyAst -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
            continue
        }

        $key = $keyAst.Value
        if ($key -ne 'Toolkit' -and $key -ne 'MSI') { continue }
        if ($sectionEntries.ContainsKey($key)) {
            throw "PSADT config content contains duplicate top-level '$key' keys."
        }

        $valuePipeline = $pair.Item2
        if ($valuePipeline -isnot [System.Management.Automation.Language.PipelineAst]) {
            throw "PSADT config top-level '$key' must be a nested hashtable."
        }
        $valueElements = @($valuePipeline.PipelineElements)
        if ($valueElements.Count -ne 1 -or
            $valueElements[0].Expression -isnot [System.Management.Automation.Language.HashtableAst]) {
            throw "PSADT config top-level '$key' must be a nested hashtable."
        }

        $sectionEntries[$key] = $valueElements[0].Expression
    }

    foreach ($sectionName in @('Toolkit', 'MSI')) {
        if (-not $sectionEntries.ContainsKey($sectionName)) {
            throw "PSADT config content is missing the top-level '$sectionName' hashtable."
        }
    }

    $targetEntries = @{
        Toolkit = @('RequireAdmin', 'LogPathNoAdminRights')
        MSI     = @('LogPathNoAdminRights')
    }
    $targetAsts = @{}
    foreach ($sectionName in $targetEntries.Keys) {
        $seen = @{}
        foreach ($pair in $sectionEntries[$sectionName].KeyValuePairs) {
            $keyAst = $pair.Item1
            if ($keyAst -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                continue
            }

            $key = $keyAst.Value
            if ($targetEntries[$sectionName] -notcontains $key) { continue }
            if ($seen.ContainsKey($key)) {
                throw "PSADT config content contains duplicate '$sectionName.$key' keys."
            }
            $seen[$key] = $pair.Item2
        }

        foreach ($key in $targetEntries[$sectionName]) {
            if (-not $seen.ContainsKey($key)) {
                throw "PSADT config content is missing '$sectionName.$key'."
            }
            $valueAst = $seen[$key]
            $valueElements = @($valueAst.PipelineElements)
            if ($valueElements.Count -ne 1 -or
                $valueElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
                throw "PSADT config '$sectionName.$key' must be a literal value."
            }

            $valueExpression = $valueElements[0].Expression
            if ($key -eq 'RequireAdmin') {
                if ($valueExpression -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
                    $valueExpression.Extent.Text -cnotin @('$true', '$false')) {
                    throw "PSADT config '$sectionName.$key' must be a literal Boolean variable."
                }
            }
            elseif ($valueExpression -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) {
                throw "PSADT config '$sectionName.$key' must be a literal string."
            }
            $targetAsts["$sectionName.$key"] = $valueAst
        }
    }

    $requireAdminAst = $targetAsts['Toolkit.RequireAdmin']
    if ($SelectedContext -eq 'System') {
        $requireAdminElements = @($requireAdminAst.PipelineElements)
        $requireAdminExpression = $null
        if ($requireAdminElements.Count -eq 1) {
            $requireAdminExpression = $requireAdminElements[0].Expression
        }
        if ($requireAdminExpression -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
            $requireAdminAst.Extent.Text -cne '$true' -or
            $requireAdminExpression.VariablePath.UserPath -cne 'true') {
            throw "PSADT config Toolkit.RequireAdmin must be the literal `$true for System context."
        }
        return $ConfigContent
    }

    $replacement = "'" + '$envLocalAppData\Logs\Software' + "'"
    $edits = @(
        [pscustomobject] @{ Start = $requireAdminAst.Extent.StartOffset; Length = $requireAdminAst.Extent.Text.Length; Value = '$false' }
        [pscustomobject] @{ Start = $targetAsts['Toolkit.LogPathNoAdminRights'].Extent.StartOffset; Length = $targetAsts['Toolkit.LogPathNoAdminRights'].Extent.Text.Length; Value = $replacement }
        [pscustomobject] @{ Start = $targetAsts['MSI.LogPathNoAdminRights'].Extent.StartOffset; Length = $targetAsts['MSI.LogPathNoAdminRights'].Extent.Text.Length; Value = $replacement }
    )

    $result = $ConfigContent
    foreach ($edit in ($edits | Sort-Object -Property Start -Descending)) {
        $result = $result.Substring(0, $edit.Start) + $edit.Value +
            $result.Substring($edit.Start + $edit.Length)
    }

    $resultTokens = $null
    $resultErrors = $null
    $resultAst = [System.Management.Automation.Language.Parser]::ParseInput(
        $result,
        [ref] $resultTokens,
        [ref] $resultErrors)
    if ($resultErrors.Count -ne 0 -or
        @($resultAst.EndBlock.Statements).Count -ne 1 -or
        $resultAst.EndBlock.Statements[0] -isnot [System.Management.Automation.Language.PipelineAst] -or
        @($resultAst.EndBlock.Statements[0].PipelineElements).Count -ne 1 -or
        $resultAst.EndBlock.Statements[0].PipelineElements[0].Expression -isnot [System.Management.Automation.Language.HashtableAst]) {
        throw 'PSADT config content became invalid after applying context values.'
    }
    return $result
}

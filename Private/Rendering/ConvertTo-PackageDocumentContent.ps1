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


function ConvertTo-DocumentText {
    <#
        .SYNOPSIS
            Renders a manifest scalar for embedding in a Markdown table cell or sentence.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return '(not resolved)' }

    $text = "$Value".Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '(not resolved)' }

    # Markdown table cells cannot contain a raw newline or an unescaped pipe.
    $text = $text -replace '\r?\n', ' '
    $text = $text -replace '\|', '\|'
    return $text
}


function Format-DocumentFileSize {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [long] $Bytes
    )

    return ('{0:N0} bytes' -f $Bytes)
}


function Format-DocumentSignatureStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Signature
    )

    if ($null -eq $Signature) { return '(not resolved)' }

    $signed = if ($Signature.IsSigned) { 'Signed' } else { 'Not signed' }
    return ('{0} ({1})' -f $signed, (ConvertTo-DocumentText $Signature.Status))
}


function Format-DocumentWrapperWarning {
    <#
        .SYNOPSIS
            A blockquote warning that msiexec /x will not uninstall a wrapper MSI's product,
            even though a ProductCode exists. Empty string when the installer is not a wrapper.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $MsiKind
    )

    if ("$MsiKind" -ne 'Wrapper') { return '' }

    return @'
> **Wrapper MSI.** This MSI wraps a vendor executable. A `ProductCode` exists syntactically,
> but `msiexec /x` against it will **not** uninstall the product. Use the vendor's own
> uninstaller, or reviewed discovery evidence, for the uninstall command shown below.
'@
}


function Format-DocumentCommand {
    <#
        .SYNOPSIS
            Renders a manifest CommandSpec through ConvertTo-CommandString -- never any other
            way, so quoting stays governed by the single quoting boundary.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Command
    )

    if ($null -eq $Command -or [string]::IsNullOrWhiteSpace("$($Command.Executable)")) {
        return '(not resolved -- see findings below)'
    }

    $argumentList = @()
    if ($Command.ArgumentList) { $argumentList = @($Command.ArgumentList | ForEach-Object { "$_" }) }

    $expectedExitCodes = @()
    if ($Command.ExpectedExitCodes) { $expectedExitCodes = @($Command.ExpectedExitCodes | ForEach-Object { [int] $_ }) }

    $spec = [CommandSpec]::new([string] $Command.Executable, [string[]] $argumentList, [int[]] $expectedExitCodes)
    return ConvertTo-CommandString -CommandSpec $spec
}


function Format-DocumentDetectionSection {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]] $DetectionSpec
    )

    $rules = @($DetectionSpec)
    if ($rules.Count -eq 0) {
        return '_No detection method could be resolved. See the findings below before deploying this package._'
    }

    $rule = $rules[0]
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('| Field | Value |')
    $lines.Add('|---|---|')
    $lines.Add('| Kind | {0} |' -f (ConvertTo-DocumentText $rule.Kind))

    switch ("$($rule.Kind)") {
        'File' {
            $lines.Add('| Path | `{0}` |' -f (ConvertTo-DocumentText $rule.Path))
            $lines.Add('| File name | `{0}` |' -f (ConvertTo-DocumentText $rule.FileName))
            $lines.Add('| Uses wildcard path | {0} |' -f (ConvertTo-DocumentText ([bool] $rule.UsesWildcardPath)))
        }
        'Registry' {
            $lines.Add('| Key path | `{0}` |' -f (ConvertTo-DocumentText $rule.KeyPath))
            $lines.Add('| Value name | `{0}` |' -f (ConvertTo-DocumentText $rule.ValueName))
            $lines.Add('| Registry view | {0} |' -f (ConvertTo-DocumentText $rule.RegistryView))
        }
    }

    $lines.Add('| Operator | {0} |' -f (ConvertTo-DocumentText $rule.Operator))
    $lines.Add('| Value | {0} |' -f (ConvertTo-DocumentText $rule.Value))
    $lines.Add('| Confidence | {0} |' -f (ConvertTo-DocumentText $rule.Confidence))
    $rationale = Get-DocumentOptionalProperty -InputObject $rule -Name 'Rationale'
    if (-not [string]::IsNullOrWhiteSpace("$rationale")) {
        $lines.Add('| Rationale | {0} |' -f (ConvertTo-DocumentText $rationale))
    }

    return ($lines -join "`n")
}


function Format-DocumentReturnCodeTable {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]] $ReturnCodeMap
    )

    $rows = @($ReturnCodeMap)
    if ($rows.Count -eq 0) { return '_No return codes modeled._' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('| Code | Meaning | Classification | Notes |')
    $lines.Add('|---:|---|---|---|')
    foreach ($row in $rows) {
        $rawNotes = Get-DocumentOptionalProperty -InputObject $row -Name 'Notes'
        $notes = if ([string]::IsNullOrWhiteSpace("$rawNotes")) { '' } else { ConvertTo-DocumentText $rawNotes }
        $lines.Add(('| {0} | {1} | {2} | {3} |' -f $row.Code, (ConvertTo-DocumentText $row.Meaning), (ConvertTo-DocumentText $row.Classification), $notes))
    }

    return ($lines -join "`n")
}


function Format-DocumentFindingList {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]] $Finding
    )

    $all = @($Finding)
    if ($all.Count -eq 0) { return '_No findings._' }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($severity in @('Blocking', 'Warning', 'Info')) {
        $group = @($all | Where-Object { "$($_.Severity)" -eq $severity })
        if ($group.Count -eq 0) { continue }

        $lines.Add("### $severity")
        $lines.Add('')
        foreach ($item in $group) {
            $fieldValue = Get-DocumentOptionalProperty -InputObject $item -Name 'Field'
            $field = if ([string]::IsNullOrWhiteSpace("$fieldValue")) { '' } else { " (field: ``$fieldValue``)" }
            $lines.Add(('- **[{0}]** {1}{2}' -f $item.Code, (ConvertTo-DocumentText $item.Message), $field))
        }
        $lines.Add('')
    }

    return ($lines -join "`n").TrimEnd()
}


function Format-DocumentProvenanceTable {
    <#
        .SYNOPSIS
            Field, resolved value, source, confidence -- and every raw candidate when raw
            evidence disagreed with the winner.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]] $ResolvedEvidence,

        [Parameter()]
        [AllowNull()]
        [object[]] $RawEvidence
    )

    $winners = @($ResolvedEvidence)
    if ($winners.Count -eq 0) { return '_No evidence recorded._' }

    $raw = @($RawEvidence)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('| Field | Resolved value | Source | Confidence | Notes |')
    $lines.Add('|---|---|---|---|---|')

    foreach ($winner in $winners) {
        $winnerNotesRaw = Get-DocumentOptionalProperty -InputObject $winner -Name 'Notes'
        $notes = if ([string]::IsNullOrWhiteSpace("$winnerNotesRaw")) { '' } else { ConvertTo-DocumentText $winnerNotesRaw }
        $lines.Add(('| `{0}` | {1} | {2} | {3} | {4} |' -f $winner.Field, (ConvertTo-DocumentText $winner.Value), (ConvertTo-DocumentText $winner.Source), (ConvertTo-DocumentText $winner.Confidence), $notes))

        $candidates = @($raw | Where-Object { $_.Field -eq $winner.Field })
        $distinctValues = @($candidates | ForEach-Object { ConvertTo-DocumentText $_.Value } | Select-Object -Unique)
        if ($distinctValues.Count -le 1) { continue }

        foreach ($candidate in $candidates) {
            $isWinner = ($candidate.Value -eq $winner.Value -and $candidate.Source -eq $winner.Source -and $candidate.Confidence -eq $winner.Confidence)
            if ($isWinner) { continue }

            $candidateNotesRaw = Get-DocumentOptionalProperty -InputObject $candidate -Name 'Notes'
            $candidateNotes = if ([string]::IsNullOrWhiteSpace("$candidateNotesRaw")) { '' } else { ConvertTo-DocumentText $candidateNotesRaw }
            $lines.Add(('| `{0}` (raw, not selected) | {1} | {2} | {3} | {4} |' -f $candidate.Field, (ConvertTo-DocumentText $candidate.Value), (ConvertTo-DocumentText $candidate.Source), (ConvertTo-DocumentText $candidate.Confidence), $candidateNotes))
        }
    }

    return ($lines -join "`n")
}


function ConvertTo-PackageDocumentContent {
    <#
        .SYNOPSIS
            Fills Templates/PackageDocument.md.template from a parsed PackageManifest.json.

        .DESCRIPTION
            Pure rendering. Every value comes from the supplied manifest object; nothing here
            reopens the installer, touches the registry, or re-derives a fact. Token
            convention matches the rest of the repository's guardrails: two opening curly
            braces, an upper-snake-case name, two closing curly braces.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Manifest
    )

    $templatePath = Join-Path $script:TemplateRoot 'PackageDocument.md.template'
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw [System.IO.FileNotFoundException]::new("PackageDocument template not found: $templatePath")
    }
    $template = Get-Content -LiteralPath $templatePath -Raw

    $installer = $Manifest.Installer
    $packageSpec = $Manifest.PackageSpec

    $tokens = [ordered] @{
        PRODUCT_NAME        = ConvertTo-DocumentText $installer.ProductName
        GENERATOR_VERSION   = ConvertTo-DocumentText $Manifest.Generator.Version
        SCHEMA_VERSION      = ConvertTo-DocumentText $Manifest.SchemaVersion
        GENERATED_AT_UTC    = ConvertTo-DocumentText $Manifest.GeneratedAtUtc
        READINESS           = ConvertTo-DocumentText $Manifest.Readiness
        INSTALLER_FILENAME  = ConvertTo-DocumentText $installer.FileName
        SHA256              = ConvertTo-DocumentText $installer.SHA256
        FILE_SIZE           = Format-DocumentFileSize ([long] $installer.FileSize)
        SIGNATURE_STATUS    = Format-DocumentSignatureStatus $installer.Signature
        SIGNER_SUBJECT      = ConvertTo-DocumentText $installer.Signature.SignerSubject
        CONTAINER_TYPE      = ConvertTo-DocumentText $installer.ContainerType
        PAYLOAD_TYPE        = ConvertTo-DocumentText $installer.PayloadType
        MSI_KIND            = ConvertTo-DocumentText $installer.MsiKind
        ARCHITECTURE        = ConvertTo-DocumentText $installer.Architecture
        MANUFACTURER        = ConvertTo-DocumentText $installer.Manufacturer
        PRODUCT_VERSION_RAW = ConvertTo-DocumentText $installer.ProductVersionRaw
        PRODUCT_CODE        = ConvertTo-DocumentText $installer.ProductCode
        UPGRADE_CODE        = ConvertTo-DocumentText $installer.UpgradeCode
        WRAPPER_WARNING     = Format-DocumentWrapperWarning $installer.MsiKind
        INSTALL_COMMAND     = Format-DocumentCommand $packageSpec.InstallCommand
        UNINSTALL_COMMAND   = Format-DocumentCommand $packageSpec.UninstallCommand
        DETECTION_SECTION   = Format-DocumentDetectionSection $packageSpec.DetectionSpec
        SELECTED_CONTEXT    = ConvertTo-DocumentText $packageSpec.SelectedContext
        REQUIRES_LOGON      = ConvertTo-DocumentText ([bool] $packageSpec.RequiresLogonWhenUserContext)
        RETURN_CODE_TABLE   = Format-DocumentReturnCodeTable $packageSpec.ReturnCodeMap
        FINDINGS_SECTION    = Format-DocumentFindingList $Manifest.Findings
        PROVENANCE_TABLE    = Format-DocumentProvenanceTable $installer.ResolvedEvidence $installer.Evidence
    }

    $content = $template
    foreach ($key in $tokens.Keys) {
        $content = $content.Replace('{{' + $key + '}}', $tokens[$key])
    }

    # A pure renderer must never let an un-filled token reach the reviewer.
    $unresolved = [regex]::Matches($content, '\{\{[A-Za-z0-9_]+\}\}')
    if ($unresolved.Count -gt 0) {
        $names = ($unresolved | ForEach-Object { $_.Value } | Select-Object -Unique) -join ', '
        throw [System.InvalidOperationException]::new("PackageDocument template has unresolved tokens: $names")
    }

    return $content
}

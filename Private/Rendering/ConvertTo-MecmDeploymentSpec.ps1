# Schema version for MecmDeploymentSpec.json. Deliberately its own constant, not the
# manifest's $script:ManifestSchemaVersion (set in PSPackageForge.psm1 from the module
# manifest's PrivateData) -- the deployment-spec shape and the packaging-manifest shape are
# two different contracts that will version independently once IntuneWin32Spec.json (README
# roadmap) exists alongside this one.
$script:MecmSpecSchemaVersion = '1.0'


function ConvertTo-MecmIsoTimestamp {
    <#
        .SYNOPSIS
            Renders a manifest timestamp field back to its round-trip ISO 8601 form.

        .DESCRIPTION
            ConvertFrom-Json's behaviour for an ISO-8601-shaped string differs by PowerShell
            edition: Windows PowerShell 5.1 leaves Manifest.GeneratedAtUtc as the plain string
            Write-PackageManifest wrote, but PowerShell 7's ConvertFrom-Json recognises the
            shape and parses it into a [DateTime] instead. Left alone, that [DateTime] would
            re-stringify through culture-formatted ToString() (e.g. '08/20/2026 13:07:01')
            instead of the manifest's own round-trippable 'o'-format text -- silently changing
            what SourceManifest.GeneratedAtUtc says depending only on which PowerShell edition
            rendered the spec. This normalises both cases back to the same 'o'-format string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToString('o') }
    return "$Value"
}


function ConvertTo-MecmCommandLine {
    <#
        .SYNOPSIS
            Reconstructs a manifest CommandSpec JSON node into a Windows command-line string.

        .DESCRIPTION
            The same reconstruction ConvertTo-PackageDocumentContent's Format-DocumentCommand
            uses: rebuild a [CommandSpec] from the manifest's structured command JSON and hand
            it to ConvertTo-CommandString, the module's single quoting boundary (plan §5.2).
            Quoting is not reimplemented here.

            Returns $null, not a placeholder string, when the command did not resolve. Unlike
            Format-DocumentCommand's '(not resolved -- see findings below)', this value lands
            in a JSON field a deployment tool will consume, not a Markdown cell meant for a
            human reviewer -- a sentinel string in a machine-readable ConfigMgr script command
            field would be actively harmful.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Command
    )

    $executable = Get-DocumentOptionalProperty -InputObject $Command -Name 'Executable'
    if ($null -eq $Command -or [string]::IsNullOrWhiteSpace("$executable")) {
        return $null
    }

    $argumentList = @()
    $rawArguments = Get-DocumentOptionalProperty -InputObject $Command -Name 'ArgumentList'
    if ($rawArguments) { $argumentList = @($rawArguments | ForEach-Object { "$_" }) }

    $expectedExitCodes = @()
    $rawExitCodes = Get-DocumentOptionalProperty -InputObject $Command -Name 'ExpectedExitCodes'
    if ($rawExitCodes) { $expectedExitCodes = @($rawExitCodes | ForEach-Object { [int] $_ }) }

    $spec = [CommandSpec]::new([string] $executable, [string[]] $argumentList, [int[]] $expectedExitCodes)
    return ConvertTo-CommandString -CommandSpec $spec
}


function ConvertTo-MecmReturnCodeType {
    <#
        .SYNOPSIS
            Maps a manifest ReturnCodeMapping Classification to MECM's script-DeploymentType
            return-code Type enum.

        .DESCRIPTION
            PSPackageForge's ReturnCodeClass (PSPackageForge.psm1) and MECM's own return-code
            Type are both small, deliberately-modelled enums (plan §7.6), and they line up
            one-to-one:

                Success                -> Success
                SuccessRebootRequired  -> SoftReboot
                SuccessRebootInitiated -> HardReboot
                Retry                  -> FastRetry
                Failure                -> Failure

            An unrecognised classification maps to Failure, never to a success-shaped MECM
            type. The module's founding rule is to never emit a confident wrong answer (plan
            §2); mapping an unknown classification to anything but Failure would let a code
            this tool cannot explain report green across a fleet, exactly the class of mistake
            the ReturnCodeClass enum's own doc comment calls out for 1619.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [string] $Classification
    )

    switch ("$Classification") {
        'Success'                { return 'Success' }
        'SuccessRebootRequired'  { return 'SoftReboot' }
        'SuccessRebootInitiated' { return 'HardReboot' }
        'Retry'                  { return 'FastRetry' }
        'Failure'                { return 'Failure' }
        default                  { return 'Failure' }
    }
}


function ConvertTo-MecmDeploymentSpec {
    <#
        .SYNOPSIS
            Renders MecmDeploymentSpec.json (the README roadmap's "MECM and Intune deployment
            specifications" item) from a parsed PackageManifest.json.

        .DESCRIPTION
            A pure renderer, exactly like ConvertTo-PackageDocumentContent: every field maps
            straight from the manifest object supplied by the caller, and nothing here
            re-derives or reinterprets a packaging decision. The manifest remains the single
            authoritative source (plan §5.4); this function only reshapes it into the schema
            MECM's script-DeploymentType import expects.

            SourceManifest design choice: the brief for this renderer allows either hashing
            the manifest file on disk, or tying the spec to its manifest via
            Manifest.GeneratedAtUtc + Installer.SHA256. This function takes the latter. It
            receives only the already-parsed manifest object -- the same signature shape as
            ConvertTo-PackageDocumentContent's -Manifest parameter -- and has no file path to
            hash. Reaching out to disk from here to hash a file whose path this function was
            never given would break the pure-renderer contract every other function in
            Private/Rendering upholds; New-MecmDeploymentSpec (the public entry point) is
            where a file path exists, and it already re-parses and re-writes JSON the same way
            New-PackageDocument does, which is a strong enough tie back to the source manifest
            without adding a second file-hashing responsibility to a renderer.

            SourceManifest.GeneratedAtUtc is normalised back to 'o'-format text through
            ConvertTo-MecmIsoTimestamp, because PowerShell 7's ConvertFrom-Json (unlike
            Windows PowerShell 5.1's) parses an ISO-8601-shaped JSON string straight into a
            [DateTime], and re-stringifying that without care would render the field
            differently depending only on which PowerShell edition ran the scaffold.

            Three operator-supplied values -- ContentSourcePath, MaxRuntimeMinutes,
            EstimatedRuntimeMinutes -- are deliberately NOT read from the manifest. No
            installer evidence could ever determine an organization's content-source UNC path
            or how long a real install takes on real hardware; treating them as evidence-
            resolved fields would be exactly the "confident wrong answer" plan §2 forbids.
            They are parameters here, default to null (content source, estimated runtime) or
            the ConfigMgr platform default (120 minutes for max runtime), and an unsupplied
            value always raises a Finding so the gap is visible in the emitted spec rather than
            silently defaulted.

            Field reads use Get-DocumentOptionalProperty (defined alongside
            ConvertTo-PackageDocumentContent, in the same Private/Rendering scope) throughout,
            not only for the manifest's own conditionally-emitted keys but for every manifest
            field this function touches. ConvertTo-PackageDocumentContent can read PackageSpec
            fields directly because it is only ever handed a manifest Write-PackageManifest
            produced. This renderer is also exercised in tests against small, hand-built
            manifest objects (a per-user "Obsidian-shape" fixture, a File-detection
            "KiCad-shape" fixture) that do not necessarily populate every key
            PackageSpec.ToOrderedDictionary would -- so the defensive read is used everywhere
            here, which is a deliberate broadening of the existing pattern rather than a
            departure from it.

        .PARAMETER Manifest
            The parsed PackageManifest.json object (as ConvertFrom-Json returns it).

        .PARAMETER ContentSourcePath
            The organization's content-source UNC path for this deployment type's files. Not
            resolved from evidence -- see DESCRIPTION.

        .PARAMETER MaxRuntimeMinutes
            Operator-supplied estimated maximum runtime. Defaults to 120 (the ConfigMgr
            platform default) when not supplied, with a Finding explaining why.

        .PARAMETER EstimatedRuntimeMinutes
            Operator-supplied estimated typical runtime. Null when not supplied.

        .OUTPUTS
            System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Manifest,

        [Parameter()]
        [AllowNull()]
        [string] $ContentSourcePath,

        [Parameter()]
        [AllowNull()]
        [Nullable[int]] $MaxRuntimeMinutes,

        [Parameter()]
        [AllowNull()]
        [Nullable[int]] $EstimatedRuntimeMinutes
    )

    $installer    = Get-DocumentOptionalProperty -InputObject $Manifest -Name 'Installer'
    $packageSpec  = Get-DocumentOptionalProperty -InputObject $Manifest -Name 'PackageSpec'
    $findings     = [System.Collections.Generic.List[Finding]]::new()

    # ---- Detection: mirrors the single-above-Low-confidence gate New-PackageScaffold.ps1
    # ---- applies before it will call New-DetectionMethod, but reads the manifest's already-
    # ---- resolved DetectionSpec instead of re-resolving anything. A manifest that omits the
    # ---- DetectionSpec key (or carries JSON null) must land in the unresolved branch, not
    # ---- count a single $null element as one resolved rule.
    $detectionRules = @(@(Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'DetectionSpec') |
        Where-Object { $null -ne $_ })
    $detection = $null
    if ($detectionRules.Count -eq 1 -and
        "$(Get-DocumentOptionalProperty -InputObject $detectionRules[0] -Name 'Confidence')" -ne 'Low') {
        $detection = [ordered] @{
            Method         = 'Script'
            ScriptFile     = 'Detect-Application.ps1'
            ScriptLanguage = 'PowerShell'
            RunAs32Bit     = [bool] (Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'RunDetectionAs32Bit')
        }
    }
    else {
        $findings.Add((New-ForgeFinding -Severity Warning -Code 'MECM_DETECTION_UNRESOLVED' `
            -Message 'The manifest does not carry exactly one above-Low-confidence detection method, so a ConfigMgr script-detection block could not be scaffolded. Resolve detection in the packaging manifest before importing this deployment type.' `
            -Field 'Detection'))
    }

    # ---- UserExperience -------------------------------------------------------------------
    $selectedContext = "$(Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'SelectedContext')"
    $installBehavior = $null
    switch ($selectedContext) {
        'System' { $installBehavior = 'InstallForSystem' }
        'User'   { $installBehavior = 'InstallForUser' }
        default {
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'MECM_INSTALL_BEHAVIOR_UNRESOLVED' `
                -Message "PackageSpec.SelectedContext ('$selectedContext') is neither System nor User, so MECM InstallBehavior could not be derived. Resolve the install context in the packaging manifest before importing this deployment type." `
                -Field 'InstallBehavior'))
        }
    }

    $requiresLogon = [bool] (Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'RequiresLogonWhenUserContext')
    $logonRequirement = if ($installBehavior -eq 'InstallForUser' -or $requiresLogon) {
        'OnlyWhenUserLoggedOn'
    }
    else {
        'WhetherOrNotUserLoggedOn'
    }

    $userExperience = [ordered] @{
        InstallBehavior  = $installBehavior
        LogonRequirement = $logonRequirement
    }

    # ---- Runtime ----------------------------------------------------------------------------
    $resolvedMaxRuntimeMinutes = $MaxRuntimeMinutes
    if ($null -eq $resolvedMaxRuntimeMinutes) {
        $resolvedMaxRuntimeMinutes = 120
        $findings.Add((New-ForgeFinding -Severity Info -Code 'MECM_MAX_RUNTIME_DEFAULTED' `
            -Message 'MaxRuntimeMinutes was not supplied. PSPackageForge never measures an installer''s actual run time, so the ConfigMgr platform default of 120 minutes was used instead of a real estimate. Supply -MaxRuntimeMinutes with a measured value before deploying at scale.' `
            -Field 'MaxRuntimeMinutes'))
    }

    # ---- ContentSourcePath --------------------------------------------------------------
    $resolvedContentSourcePath = $ContentSourcePath
    if ([string]::IsNullOrWhiteSpace($ContentSourcePath)) {
        $resolvedContentSourcePath = $null
        $findings.Add((New-ForgeFinding -Severity Warning -Code 'MECM_CONTENT_SOURCE_UNSET' `
            -Message 'ContentSourcePath was not supplied. Set it to the organization''s content-source UNC path before importing this deployment type into ConfigMgr; the package''s staged output folder is the content this deployment type expects to find there.' `
            -Field 'ContentSourcePath'))
    }

    # ---- ReturnCodes -------------------------------------------------------------------------
    $returnCodeRows = @(Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'ReturnCodeMap')
    $returnCodes = @($returnCodeRows | ForEach-Object {
        [ordered] @{
            Code     = [int] (Get-DocumentOptionalProperty -InputObject $_ -Name 'Code')
            CodeType = ConvertTo-MecmReturnCodeType -Classification "$(Get-DocumentOptionalProperty -InputObject $_ -Name 'Classification')"
            Name     = "$(Get-DocumentOptionalProperty -InputObject $_ -Name 'Meaning')"
        }
    })

    $productName = "$(Get-DocumentOptionalProperty -InputObject $installer -Name 'ProductName')"

    $deploymentType = [ordered] @{
        Name                    = "$productName - Script Installer"
        Technology              = 'Script'
        InstallCommand          = ConvertTo-MecmCommandLine -Command (Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'InstallCommand')
        UninstallCommand        = ConvertTo-MecmCommandLine -Command (Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'UninstallCommand')
        ContentSourcePath       = $resolvedContentSourcePath
        Detection               = $detection
        UserExperience          = $userExperience
        MaxRuntimeMinutes       = [int] $resolvedMaxRuntimeMinutes
        EstimatedRuntimeMinutes = $EstimatedRuntimeMinutes
        ReturnCodes             = $returnCodes
    }

    return [ordered] @{
        SchemaVersion  = $script:MecmSpecSchemaVersion
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Generator      = [ordered] @{
            Name    = 'PSPackageForge'
            Version = "$script:GeneratorVersion"
        }
        SourceManifest = [ordered] @{
            SchemaVersion   = "$(Get-DocumentOptionalProperty -InputObject $Manifest -Name 'SchemaVersion')"
            GeneratedAtUtc  = ConvertTo-MecmIsoTimestamp (Get-DocumentOptionalProperty -InputObject $Manifest -Name 'GeneratedAtUtc')
            InstallerSHA256 = "$(Get-DocumentOptionalProperty -InputObject $installer -Name 'SHA256')"
        }
        Application    = [ordered] @{
            LocalizedDisplayName = $productName
            Publisher             = "$(Get-DocumentOptionalProperty -InputObject $installer -Name 'Manufacturer')"
            SoftwareVersion       = "$(Get-DocumentOptionalProperty -InputObject $installer -Name 'ProductVersionRaw')"
        }
        DeploymentType = @($deploymentType)
        Findings       = @($findings | ForEach-Object { $_.ToOrderedDictionary() })
        Readiness      = "$(Get-DocumentOptionalProperty -InputObject $Manifest -Name 'Readiness')"
    }
}

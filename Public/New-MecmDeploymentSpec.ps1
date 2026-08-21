function New-MecmDeploymentSpec {
    <#
        .SYNOPSIS
            Renders MecmDeploymentSpec.json from a PackageManifest.json.

        .DESCRIPTION
            This is a deployment-target adapter, not a second source of truth. The package
            manifest stays authoritative (plan §5.4); everything this command emits is
            reshaped from it by the pure renderer ConvertTo-MecmDeploymentSpec, the same way
            New-PackageDocument reshapes the manifest into PackageDocument.md. Nothing here
            rediscovers or reinterprets a packaging decision.

            Three parameters -- ContentSourcePath, MaxRuntimeMinutes, EstimatedRuntimeMinutes
            -- are deliberately operator inputs, not evidence-resolved manifest fields. No
            amount of installer introspection could ever tell PSPackageForge which UNC share
            an organization's ConfigMgr content library uses, or how long an install actually
            takes on real hardware; those are organization/site facts, not installer facts,
            and treating them as anything the tool "resolved" from evidence would be exactly
            the confident-wrong-answer failure mode plan §2 exists to prevent. Leaving them
            unsupplied still produces a usable spec: a missing content source or an unmeasured
            runtime becomes a null value plus a Finding recorded directly in the emitted JSON,
            never a silently invented default that only the max-runtime field receives (and
            there specifically because ConfigMgr itself defines 120 minutes as its own
            platform default, not because PSPackageForge is guessing).

            MecmDeploymentSpec.json is written next to the supplied manifest by default,
            mirroring how PackageDocument.md sits alongside PackageManifest.json in the
            scaffold's output root.

        .PARAMETER ManifestPath
            Path to an existing PackageManifest.json.

        .PARAMETER OutputPath
            Where to write MecmDeploymentSpec.json. Defaults to a file named
            MecmDeploymentSpec.json next to ManifestPath.

        .PARAMETER ContentSourcePath
            The organization's content-source UNC path for this deployment type's files. Not
            resolved from installer evidence -- see DESCRIPTION. Omit to emit null plus a
            Finding (MECM_CONTENT_SOURCE_UNSET) marking it as required before import.

        .PARAMETER MaxRuntimeMinutes
            Operator-supplied maximum runtime in minutes. Omit to use ConfigMgr's own
            platform default of 120, recorded with a Finding (MECM_MAX_RUNTIME_DEFAULTED)
            explaining that PSPackageForge cannot measure actual install duration.

        .PARAMETER EstimatedRuntimeMinutes
            Operator-supplied estimated typical runtime in minutes. Omit to emit null; no
            Finding is raised beyond the one MaxRuntimeMinutes already records.

        .OUTPUTS
            PSPackageForge.MecmDeploymentSpecResult
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('PSPackageForge.MecmDeploymentSpecResult')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ManifestPath,

        [Parameter()]
        [string] $OutputPath,

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

    $resolvedManifestPath = (Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).ProviderPath
    $manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json

    $specPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        Join-Path (Split-Path -Path $resolvedManifestPath -Parent) 'MecmDeploymentSpec.json'
    }
    else {
        $OutputPath
    }

    if ($PSCmdlet.ShouldProcess($specPath, 'Render MecmDeploymentSpec.json')) {
        $spec = ConvertTo-MecmDeploymentSpec -Manifest $manifest -ContentSourcePath $ContentSourcePath `
            -MaxRuntimeMinutes $MaxRuntimeMinutes -EstimatedRuntimeMinutes $EstimatedRuntimeMinutes

        $parent = Split-Path -Path $specPath -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            [void] (New-Item -ItemType Directory -Path $parent -Force)
        }

        $json = $spec | ConvertTo-Json -Depth 20
        Set-Content -LiteralPath $specPath -Value $json -Encoding UTF8

        # Structural validation: prove the emitted document round-trips as JSON, the same
        # approach Write-PackageManifest uses for PackageManifest.json.
        $null = Get-Content -LiteralPath $specPath -Raw | ConvertFrom-Json

        [PSCustomObject] @{
            PSTypeName   = 'PSPackageForge.MecmDeploymentSpecResult'
            ManifestPath = $resolvedManifestPath
            SpecPath     = (Resolve-Path -LiteralPath $specPath).ProviderPath
            Findings     = $spec.Findings
        }
    }
}

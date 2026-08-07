function New-PackageScaffold {
    <#
        .SYNOPSIS
            THE entry point. Orchestrates identification, resolution, and rendering into a
            reviewable packaging bundle.

        .DESCRIPTION
            The current core milestone emits the authoritative PackageManifest.json and,
            when detection resolves above Low confidence, Detect-Application.ps1. Later
            roadmap renderers consume that manifest for documentation, PSADT, and Intune.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('PSPackageForge.ScaffoldResult')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath,

        [Parameter()]
        [AllowEmptyCollection()]
        [object[]] $AdditionalEvidence = @(),

        [Parameter()]
        [ValidateSet('Exact', 'GreaterOrEqual')]
        [string] $DetectionOperator = 'Exact',

        [Parameter()]
        [switch] $FailOnLowConfidence
    )

    if ($PSCmdlet.ShouldProcess($Path, "Generate packaging scaffold into '$OutputPath'")) {
        $installerInfo = Get-InstallerInfo -Path $Path -AdditionalEvidence $AdditionalEvidence
        $operator = Get-ForgeEnumValue -Value $DetectionOperator -Type ([DetectionOperator]) -Default ([DetectionOperator]::Exact)
        $packageSpec = Resolve-PackageSpec -InstallerInfo $installerInfo -DetectionOperator $operator

        if (-not (Test-Path -LiteralPath $OutputPath)) {
            [void] (New-Item -ItemType Directory -Path $OutputPath -Force)
        }
        $resolvedOutput = (Resolve-Path -LiteralPath $OutputPath).ProviderPath

        $stagedInstaller = Join-Path $resolvedOutput $installerInfo.FileName
        if (-not [string]::Equals($installerInfo.Path, $stagedInstaller, [StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $installerInfo.Path -Destination $stagedInstaller -Force
        }
        $stagedHash = (Get-FileHash -LiteralPath $stagedInstaller -Algorithm SHA256).Hash
        if ($stagedHash -ne $installerInfo.SHA256) {
            throw [System.IO.InvalidDataException]::new(
                "Staged installer hash mismatch. Expected $($installerInfo.SHA256), got $stagedHash.")
        }

        $detectionResult = $null
        if ($packageSpec.DetectionSpec.Count -eq 1 -and
            $packageSpec.DetectionSpec[0].Confidence -ne [ConfidenceLevel]::Low) {
            $detectionResult = New-DetectionMethod -DetectionSpec $packageSpec.DetectionSpec[0] -OutputPath $resolvedOutput
        }

        $manifestPath = Join-Path $resolvedOutput 'PackageManifest.json'
        $manifestFile = Write-PackageManifest -InstallerInfo $installerInfo -PackageSpec $packageSpec -OutputPath $manifestPath

        if ($FailOnLowConfidence -and $packageSpec.Readiness -eq [ReadinessLevel]::NeedsInput) {
            throw [System.InvalidOperationException]::new(
                "Package readiness is NeedsInput. Review '$($manifestFile.FullName)' for blocking findings.")
        }

        [PSCustomObject] @{
            PSTypeName       = 'PSPackageForge.ScaffoldResult'
            InstallerInfo    = $installerInfo
            PackageSpec      = $packageSpec
            ManifestPath     = $manifestFile.FullName
            DetectionPath    = if ($null -ne $detectionResult) { $detectionResult.ScriptPath } else { $null }
            InstallerPath    = $stagedInstaller
            OutputPath       = $resolvedOutput
            Readiness        = $packageSpec.Readiness
        }
    }
}

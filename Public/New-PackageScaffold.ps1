function New-PackageScaffold {
    <#
        .SYNOPSIS
            THE entry point. Orchestrates identification, resolution, and rendering into a
            reviewable packaging bundle.

        .DESCRIPTION
            Emits the authoritative PackageManifest.json, PackageDocument.md and, when
            detection resolves above Low confidence, Detect-Application.ps1. Before it
            returns, it runs Test-ScaffoldOutput as a self-check on its own emitted files --
            unresolved template tokens, generated PowerShell that fails to parse, a manifest
            referencing a missing file, an oversized detection script, or a staged-installer
            hash mismatch. Any such finding is folded back into the manifest and document
            before the final result is returned. Later roadmap renderers (PSADT, IntuneWin)
            consume the same manifest.

        .PARAMETER DiscoveryData
            Optional installed-application discovery JSON written by Get-InstalledAppInfo
            on a reference machine. Imported registry observations are attributed to
            DiscoveryJson and merged with the installer's own evidence.

        .PARAMETER DiscoveryMatchId
            Stable match identifier to select when DiscoveryData contains more than one
            installed application. A document with one match is selected automatically;
            a document with several is never guessed.
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
        [string] $DiscoveryData,

        [Parameter()]
        [string] $DiscoveryMatchId,

        [Parameter()]
        [ValidateSet('Exact', 'GreaterOrEqual')]
        [string] $DetectionOperator = 'Exact',

        [Parameter()]
        [switch] $FailOnLowConfidence
    )

    if (-not [string]::IsNullOrWhiteSpace($DiscoveryMatchId) -and
        [string]::IsNullOrWhiteSpace($DiscoveryData)) {
        throw [System.ArgumentException]::new(
            '-DiscoveryMatchId requires -DiscoveryData.', 'DiscoveryMatchId')
    }

    if ($PSCmdlet.ShouldProcess($Path, "Generate packaging scaffold into '$OutputPath'")) {
        $combinedEvidence = [System.Collections.Generic.List[object]]::new()
        foreach ($record in $AdditionalEvidence) { $combinedEvidence.Add($record) }

        $discoveryResult = $null
        if (-not [string]::IsNullOrWhiteSpace($DiscoveryData)) {
            $discoveryResult = Read-InstalledAppDiscoveryData -Path $DiscoveryData -MatchId $DiscoveryMatchId
            foreach ($record in $discoveryResult.Evidence) { $combinedEvidence.Add($record) }
        }

        $installerInfo = Get-InstallerInfo -Path $Path -AdditionalEvidence $combinedEvidence.ToArray()
        if ($null -ne $discoveryResult) {
            $installerInfo.Findings = @($installerInfo.Findings) + @($discoveryResult.Findings)
        }
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

        $documentResult = New-PackageDocument -ManifestPath $manifestFile.FullName

        # Self-check the emitted files against their own manifest before returning. A
        # failure here means the renderers produced something inconsistent with what they
        # just wrote, not a judgement about the target application.
        $validationFindings = @(Test-ScaffoldOutput -OutputPath $resolvedOutput -ManifestPath $manifestFile.FullName)

        if ($validationFindings.Count -gt 0) {
            $installerInfo.Findings = @($installerInfo.Findings) + $validationFindings

            $blocking = @($validationFindings | Where-Object { $_.IsBlocking() })
            if ($blocking.Count -gt 0) {
                $packageSpec.BlockingFindings = @($packageSpec.BlockingFindings) + $blocking
                $null = $packageSpec.RecalculateReadiness()
            }

            $manifestFile = Write-PackageManifest -InstallerInfo $installerInfo -PackageSpec $packageSpec -OutputPath $manifestPath
            $documentResult = New-PackageDocument -ManifestPath $manifestFile.FullName
        }

        if ($FailOnLowConfidence -and $packageSpec.Readiness -eq [ReadinessLevel]::NeedsInput) {
            throw [System.InvalidOperationException]::new(
                "Package readiness is NeedsInput. Review '$($manifestFile.FullName)' for blocking findings.")
        }

        [PSCustomObject] @{
            PSTypeName       = 'PSPackageForge.ScaffoldResult'
            InstallerInfo    = $installerInfo
            PackageSpec      = $packageSpec
            ManifestPath     = $manifestFile.FullName
            DocumentPath     = if ($null -ne $documentResult) { $documentResult.DocumentPath } else { $null }
            DetectionPath    = if ($null -ne $detectionResult) { $detectionResult.ScriptPath } else { $null }
            InstallerPath    = $stagedInstaller
            OutputPath       = $resolvedOutput
            Readiness        = $packageSpec.Readiness
            DiscoveryMatchId = if ($null -ne $discoveryResult) { $discoveryResult.MatchId } else { $null }
        }
    }
}

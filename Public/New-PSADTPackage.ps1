function New-PSADTPackage {
    <#
        .SYNOPSIS
            Generates a PSAppDeployToolkit 4.0.6 package from PackageManifest.json.

        .DESCRIPTION
            PackageManifest.json remains authoritative. This command validates the manifest,
            asks the exact pinned PSAppDeployToolkit module to create its native v4 template,
            and applies a pure render plan to the stable session-property assignments and
            install/uninstall task markers in that template. Structured CommandSpec fields
            become Start-ADTProcess calls without parsing or rebuilding command-line strings.

            The PSADT module must already be available at the version recorded by the
            manifest (currently 4.0.6), either as an installed module or through an explicit
            -PSADTModulePath. PSPackageForge never downloads or upgrades toolkit code.

            The staged installer beside PackageManifest.json is hash-checked against the
            manifest before it is copied into the generated template's Files directory.
            Readiness = NeedsInput, unresolved commands, a schema/toolkit mismatch, a stale
            installer, or a non-empty output path all fail before package rendering.

        .PARAMETER ManifestPath
            Path to the authoritative PackageManifest.json.

        .PARAMETER OutputPath
            Package root to create. Defaults to a Package directory beside ManifestPath.

        .PARAMETER PSADTModulePath
            Optional exact path to PSAppDeployToolkit.psd1. When omitted, the pinned version
            must already be discoverable through Get-Module -ListAvailable.

        .OUTPUTS
            PSPackageForge.PSADTPackageResult
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('PSPackageForge.PSADTPackageResult')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ManifestPath,

        [Parameter()]
        [string] $OutputPath,

        [Parameter()]
        [string] $PSADTModulePath
    )

    $resolvedManifestPath = (Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).ProviderPath
    $manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json

    $manifestSchemaVersion = "$(Get-DocumentOptionalProperty -InputObject $manifest -Name 'SchemaVersion')"
    if ($manifestSchemaVersion -ne "$script:ManifestSchemaVersion") {
        throw [System.IO.InvalidDataException]::new(
            "PackageManifest.json schema '$manifestSchemaVersion' is not supported; expected '$script:ManifestSchemaVersion'.")
    }

    $generator = Get-DocumentOptionalProperty -InputObject $manifest -Name 'Generator'
    $requiredVersionText = "$(Get-DocumentOptionalProperty -InputObject $generator -Name 'RequiredPSADTVersion')"
    if ($requiredVersionText -ne "$script:RequiredPSADTVersion") {
        throw [System.IO.InvalidDataException]::new(
            "PackageManifest.json requires PSADT '$requiredVersionText', but PSPackageForge is pinned to '$script:RequiredPSADTVersion'.")
    }
    $requiredVersion = [Version] $requiredVersionText

    $readiness = "$(Get-DocumentOptionalProperty -InputObject $manifest -Name 'Readiness')"
    if ($readiness -ne 'ReviewRequired') {
        throw [System.InvalidOperationException]::new(
            "PackageManifest.json readiness is '$readiness'. Resolve blocking findings before generating a runnable PSADT package.")
    }

    # Build the plan before any write. Besides preserving renderer purity, this validates
    # both commands and every expected exit-code classification before a template exists.
    $renderPlan = ConvertTo-PSADTRenderPlan -Manifest $manifest

    $manifestDirectory = Split-Path -Path $resolvedManifestPath -Parent
    $installer = Get-DocumentOptionalProperty -InputObject $manifest -Name 'Installer'
    $installerPathText = "$(Get-DocumentOptionalProperty -InputObject $installer -Name 'Path')"
    $installerFileName = "$(Get-DocumentOptionalProperty -InputObject $installer -Name 'FileName')"
    $expectedHash = "$(Get-DocumentOptionalProperty -InputObject $installer -Name 'SHA256')"
    if ([string]::IsNullOrWhiteSpace($installerPathText) -or
        [string]::IsNullOrWhiteSpace($installerFileName) -or
        [string]::IsNullOrWhiteSpace($expectedHash)) {
        throw [System.IO.InvalidDataException]::new(
            'PackageManifest.json must contain Installer.Path, Installer.FileName, and Installer.SHA256 before a PSADT package can be generated.')
    }

    $pathSeparators = [char[]] @('\', '/')
    if ([System.IO.Path]::IsPathRooted($installerPathText) -or
        $installerPathText.IndexOfAny($pathSeparators) -ge 0 -or
        $installerFileName.IndexOfAny($pathSeparators) -ge 0 -or
        -not [string]::Equals($installerPathText, $installerFileName, [StringComparison]::OrdinalIgnoreCase)) {
        throw [System.IO.InvalidDataException]::new(
            'Installer.Path and Installer.FileName must name the same staged file directly beside PackageManifest.json.')
    }

    $candidateInstallerPath = Join-Path -Path $manifestDirectory -ChildPath $installerPathText
    $resolvedInstallerPath = (Resolve-Path -LiteralPath $candidateInstallerPath -ErrorAction Stop).ProviderPath
    $actualHash = (Get-FileHash -LiteralPath $resolvedInstallerPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($actualHash, $expectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw [System.IO.InvalidDataException]::new(
            "Staged installer hash mismatch. Expected $expectedHash, got $actualHash.")
    }

    $resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        Join-Path -Path $manifestDirectory -ChildPath 'Package'
    }
    else {
        $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    }
    $outputLeaf = Split-Path -Path $resolvedOutputPath -Leaf
    $outputParent = Split-Path -Path $resolvedOutputPath -Parent
    if ([string]::IsNullOrWhiteSpace($outputLeaf) -or [string]::IsNullOrWhiteSpace($outputParent)) {
        throw [System.ArgumentException]::new("OutputPath '$resolvedOutputPath' must identify a package directory.")
    }
    if (Test-Path -LiteralPath $resolvedOutputPath) {
        $existingEntries = @(Get-ChildItem -LiteralPath $resolvedOutputPath -Force)
        if ($existingEntries.Count -gt 0) {
            throw [System.IO.IOException]::new(
                "OutputPath '$resolvedOutputPath' already exists and is not empty. Choose an empty directory; this command does not overwrite packages.")
        }
    }

    if ($PSCmdlet.ShouldProcess($resolvedOutputPath, "Generate PSAppDeployToolkit $requiredVersion package")) {
        $templateCommand = Resolve-PSADTTemplateCommand -RequiredVersion $requiredVersion `
            -ModulePath $PSADTModulePath

        if (-not (Test-Path -LiteralPath $outputParent)) {
            [void] (New-Item -ItemType Directory -Path $outputParent -Force)
        }

        $templateResult = & $templateCommand -Destination $outputParent -Name $outputLeaf `
            -Version 4 -PassThru
        if ($null -eq $templateResult -or -not (Test-Path -LiteralPath $resolvedOutputPath -PathType Container)) {
            throw [System.IO.IOException]::new(
                "New-ADTTemplate did not create the expected package directory '$resolvedOutputPath'.")
        }

        $deploymentScriptPath = Join-Path -Path $resolvedOutputPath -ChildPath 'Invoke-AppDeployToolkit.ps1'
        if (-not (Test-Path -LiteralPath $deploymentScriptPath -PathType Leaf)) {
            throw [System.IO.InvalidDataException]::new(
                "The PSADT $requiredVersion template did not contain Invoke-AppDeployToolkit.ps1.")
        }

        $nativeContent = Get-Content -LiteralPath $deploymentScriptPath -Raw
        $renderedContent = ConvertTo-PSADTTemplateContent -TemplateContent $nativeContent -RenderPlan $renderPlan
        Set-Content -LiteralPath $deploymentScriptPath -Value $renderedContent -Encoding UTF8

        $filesPath = Join-Path -Path $resolvedOutputPath -ChildPath 'Files'
        if (-not (Test-Path -LiteralPath $filesPath -PathType Container)) {
            throw [System.IO.InvalidDataException]::new(
                "The PSADT $requiredVersion template did not contain its Files directory.")
        }
        $packagedInstallerPath = Join-Path -Path $filesPath -ChildPath $installerFileName
        Copy-Item -LiteralPath $resolvedInstallerPath -Destination $packagedInstallerPath

        [PSCustomObject] @{
            PSTypeName           = 'PSPackageForge.PSADTPackageResult'
            ManifestPath         = $resolvedManifestPath
            PackagePath          = (Resolve-Path -LiteralPath $resolvedOutputPath).ProviderPath
            DeploymentScriptPath = (Resolve-Path -LiteralPath $deploymentScriptPath).ProviderPath
            InstallerPath        = (Resolve-Path -LiteralPath $packagedInstallerPath).ProviderPath
            PSADTVersion         = "$requiredVersion"
        }
    }
}

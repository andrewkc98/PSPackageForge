function New-PSADTPackage {
    <#
        .SYNOPSIS
            Generates a receipt-backed PSAppDeployToolkit 4.0.6 package.

        .DESCRIPTION
            The schema-2 manifest is validated before any output is written. The exact
            pinned toolkit renders into a unique sibling staging directory; PSPackageForge
            patches the frontend and context config, copies the staged installer, writes
            and validates a receipt, then publishes the complete package with a directory
            rename. A non-empty existing destination is never overwritten.

        .PARAMETER ManifestPath
            Path to the authoritative PackageManifest.json.

        .PARAMETER OutputPath
            Package root to create. Defaults to a Package directory beside ManifestPath.

        .PARAMETER PSADTModulePath
            Optional exact path to PSAppDeployToolkit.psd1.

        .OUTPUTS
            PSPackageForge.PSADTPackageResult
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('PSPackageForge.PSADTPackageResult')]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ManifestPath,
        [Parameter()] [string] $OutputPath,
        [Parameter()] [string] $PSADTModulePath
    )

    $manifestInput = Read-PackageForgeManifest -ManifestPath $ManifestPath -RequireRunnable
    $manifest = $manifestInput.Manifest
    $requiredVersion = [Version] $manifestInput.RequiredPSADTVersion
    $renderPlan = ConvertTo-PSADTRenderPlan -Manifest $manifest
    $installer = Get-DocumentOptionalProperty -InputObject $manifest -Name 'Installer'
    $installerFileName = [string] (Get-DocumentOptionalProperty -InputObject $installer -Name 'FileName')
    $packageSpec = Get-DocumentOptionalProperty -InputObject $manifest -Name 'PackageSpec'
    $selectedContext = [string] (Get-DocumentOptionalProperty -InputObject $packageSpec -Name 'SelectedContext')

    $resolvedOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        Join-Path -Path $manifestInput.ScaffoldRoot -ChildPath 'Package'
    }
    else {
        [System.IO.Path]::GetFullPath(
            $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath))
    }
    $outputLeaf = Split-Path -Path $resolvedOutputPath -Leaf
    $outputParent = Split-Path -Path $resolvedOutputPath -Parent
    if ([string]::IsNullOrWhiteSpace($outputLeaf) -or [string]::IsNullOrWhiteSpace($outputParent)) {
        throw [System.ArgumentException]::new("OutputPath '$resolvedOutputPath' must identify a package directory.")
    }
    if (Test-Path -LiteralPath $resolvedOutputPath) {
        if (-not (Test-Path -LiteralPath $resolvedOutputPath -PathType Container)) {
            throw [System.IO.IOException]::new("OutputPath '$resolvedOutputPath' exists and is not a directory.")
        }
        if (@(Get-ChildItem -LiteralPath $resolvedOutputPath -Force -ErrorAction Stop).Count -gt 0) {
            throw [System.IO.IOException]::new(
                "OutputPath '$resolvedOutputPath' already exists and is not empty. This command does not overwrite packages.")
        }
    }

    if (-not $PSCmdlet.ShouldProcess($resolvedOutputPath, "Generate receipt-backed PSAppDeployToolkit $requiredVersion package")) {
        return
    }

    $templateCommand = Resolve-PSADTTemplateCommand -RequiredVersion $requiredVersion -ModulePath $PSADTModulePath
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
        [void] (New-Item -ItemType Directory -Path $outputParent -Force -ErrorAction Stop)
    }
    do {
        $stageLeaf = '.psforge-' + [Guid]::NewGuid().ToString('N')
        $stagePath = Join-Path -Path $outputParent -ChildPath $stageLeaf
    } while (Test-Path -LiteralPath $stagePath)
    # The GUID path was verified absent, so this invocation owns it even if the template
    # creates only part of its output and then throws.
    $stageOwned = $true
    try {
        $templateResult = & $templateCommand -Destination $outputParent -Name $stageLeaf -Version 4 -PassThru
        if ($null -eq $templateResult -or -not (Test-Path -LiteralPath $stagePath -PathType Container)) {
            throw [System.IO.IOException]::new('New-ADTTemplate did not create the unique package staging directory.')
        }
        $stageOwned = $true

        $deploymentScriptPath = Join-Path -Path $stagePath -ChildPath 'Invoke-AppDeployToolkit.ps1'
        if (-not (Test-Path -LiteralPath $deploymentScriptPath -PathType Leaf)) {
            throw [System.IO.InvalidDataException]::new("The PSADT $requiredVersion template did not contain Invoke-AppDeployToolkit.ps1.")
        }
        $nativeContent = Get-Content -LiteralPath $deploymentScriptPath -Raw -ErrorAction Stop
        $renderedContent = ConvertTo-PSADTTemplateContent -TemplateContent $nativeContent -RenderPlan $renderPlan
        Set-Content -LiteralPath $deploymentScriptPath -Value $renderedContent -Encoding UTF8 -ErrorAction Stop

        $configPath = Join-Path -Path $stagePath -ChildPath 'Config/config.psd1'
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            throw [System.IO.InvalidDataException]::new("The PSADT $requiredVersion template did not contain Config/config.psd1.")
        }
        $configContent = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
        $patchedConfig = ConvertTo-PSADTConfigContent -ConfigContent $configContent -SelectedContext $selectedContext
        if ($patchedConfig -cne $configContent) {
            Set-Content -LiteralPath $configPath -Value $patchedConfig -Encoding UTF8 -ErrorAction Stop
        }

        $filesPath = Join-Path -Path $stagePath -ChildPath 'Files'
        if (-not (Test-Path -LiteralPath $filesPath -PathType Container)) {
            throw [System.IO.InvalidDataException]::new("The PSADT $requiredVersion template did not contain its Files directory.")
        }
        $packagedInstallerPath = Join-Path -Path $filesPath -ChildPath $installerFileName
        Copy-Item -LiteralPath $manifestInput.InstallerPath -Destination $packagedInstallerPath -ErrorAction Stop

        [void] (Write-PackageForgeReceipt -ManifestInput $manifestInput -PackagePath $stagePath)
        $validatedPackage = Test-PackageForgePackage -ManifestInput $manifestInput -PackagePath $stagePath

        # Recheck immediately before the same-volume rename. This deliberately accepts the
        # small check/rename race for one local operator, and never removes a nonempty path.
        if (Test-Path -LiteralPath $resolvedOutputPath) {
            if (-not (Test-Path -LiteralPath $resolvedOutputPath -PathType Container) -or
                @(Get-ChildItem -LiteralPath $resolvedOutputPath -Force -ErrorAction Stop).Count -gt 0) {
                throw [System.IO.IOException]::new(
                    "OutputPath '$resolvedOutputPath' became occupied before package publication.")
            }
            [System.IO.Directory]::Delete($resolvedOutputPath, $false)
        }
        [System.IO.Directory]::Move($stagePath, $resolvedOutputPath)
        $stageOwned = $false

        $finalFrontend = Join-Path -Path $resolvedOutputPath -ChildPath ([System.IO.Path]::GetFileName($validatedPackage.FrontendPath))
        $finalPayload = Join-Path -Path $resolvedOutputPath -ChildPath ('Files/' + $installerFileName)
        [PSCustomObject] @{
            PSTypeName           = 'PSPackageForge.PSADTPackageResult'
            ManifestPath         = $manifestInput.ManifestPath
            PackagePath          = $resolvedOutputPath
            DeploymentScriptPath = $finalFrontend
            InstallerPath        = $finalPayload
            PSADTVersion         = "$requiredVersion"
        }
    }
    finally {
        if ($stageOwned -and (Test-Path -LiteralPath $stagePath -PathType Container)) {
            Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

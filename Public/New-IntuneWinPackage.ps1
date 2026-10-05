function New-IntuneWinPackage {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('PSPackageForge.IntuneWinPackageResult')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath,
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $IntuneWinAppUtilPath
    )
    $preflight = Read-IntuneWinPackageInput -OutputPath $OutputPath
    $outputDirectory = $preflight.IntuneWinPath
    $buildInstructionsPath = Join-Path $preflight.OutputPath 'Build-IntuneWin.ps1'
    $result = [ordered]@{
        PSTypeName = 'PSPackageForge.IntuneWinPackageResult'
        ManifestPath = $preflight.ManifestPath
        SourcePath = $preflight.SourcePath
        BuildInstructionsPath = $buildInstructionsPath
        OutputPath = $outputDirectory
        IntuneWinPath = $null
        IntuneWinAppUtilPath = $null
        ToolAvailable = $null
        ToolExitCode = $null
        Status = 'InstructionsOnly'
        SHA256 = $null
        Findings = @()
    }
    if (-not $PSCmdlet.ShouldProcess($preflight.OutputPath, 'Generate .intunewin package')) {
        return [PSCustomObject]$result
    }
    $scriptText = ConvertTo-IntuneWinBuildScript -PackageInput $preflight
    Set-Content -LiteralPath $buildInstructionsPath -Value $scriptText -Encoding UTF8
    $resolution = Resolve-IntuneWinAppUtil -ExplicitPath $IntuneWinAppUtilPath
    $result.ToolAvailable = [bool]$resolution.ToolAvailable
    $result.Findings = @($resolution.Findings)
    if (-not $resolution.ToolAvailable) { return [PSCustomObject]$result }
    $result.IntuneWinAppUtilPath = $resolution.IntuneWinAppUtilPath
    $stagingPath = Join-Path $preflight.OutputPath ('.IntuneWin.staging-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $stagingPath) {
        throw [System.IO.IOException]::new("Could not claim unique Intune staging path '$stagingPath'.")
    }
    $stagingOwned = $false
    $removedEmptyOutput = $false
    try {
        [void](New-Item -ItemType Directory -Path $stagingPath -ErrorAction Stop)
        $stagingOwned = Test-Path -LiteralPath $stagingPath -PathType Container
        if (-not $stagingOwned -or @(Get-ChildItem -LiteralPath $stagingPath -Force -ErrorAction Stop).Count -ne 0) {
            throw [System.IO.IOException]::new('Could not establish an empty owned Intune staging directory.')
        }

        $exitCode = Invoke-IntuneWinAppUtil -IntuneWinAppUtilPath $resolution.IntuneWinAppUtilPath `
            -PackagePath $preflight.SourcePath -OutputPath $stagingPath
        $result.ToolExitCode = [int]$exitCode
        if ([int]$exitCode -ne 0) {
            throw [System.ComponentModel.Win32Exception]::new(
                "IntuneWinAppUtil.exe failed with exit code $exitCode. No package artifact was accepted.")
        }

        # Enumerate all entries (including hidden files and directories); the utility
        # must produce exactly the one expected, non-empty package artifact.
        $outputs = @(Get-ChildItem -LiteralPath $stagingPath -Force -ErrorAction Stop)
        $expectedName = 'Invoke-AppDeployToolkit.intunewin'
        if ($outputs.Count -ne 1 -or $outputs[0].PSIsContainer -or
            -not [string]::Equals($outputs[0].Name, $expectedName, [System.StringComparison]::OrdinalIgnoreCase) -or
            $outputs[0].Length -le 0) {
            throw [System.IO.IOException]::new(
                "Expected exactly one non-empty $expectedName and no other output; found $($outputs.Count) entries.")
        }
        $artifactHash = (Get-FileHash -LiteralPath $outputs[0].FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()

        # Recheck occupancy immediately before publishing. If an empty destination
        # appeared, remove only that verified-empty directory before the same-volume rename.
        if (Test-Path -LiteralPath $outputDirectory) {
            if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container) -or
                @(Get-ChildItem -LiteralPath $outputDirectory -Force -ErrorAction Stop).Count -ne 0) {
                throw [System.IO.IOException]::new(
                    "IntuneWin output '$outputDirectory' is no longer absent or empty; it was left unchanged.")
            }
            Remove-Item -LiteralPath $outputDirectory -Force -ErrorAction Stop
            $removedEmptyOutput = $true
        }
        Move-Item -LiteralPath $stagingPath -Destination $outputDirectory -ErrorAction Stop
        $stagingOwned = $false
        $removedEmptyOutput = $false
        $artifactPath = Join-Path $outputDirectory $expectedName
        $result.IntuneWinPath = $artifactPath
        $result.SHA256 = $artifactHash
        $result.Status = 'Built'
        return [PSCustomObject]$result
    }
    finally {
        if ($stagingOwned -and (Test-Path -LiteralPath $stagingPath -PathType Container)) {
            Remove-Item -LiteralPath $stagingPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($removedEmptyOutput -and -not (Test-Path -LiteralPath $outputDirectory)) {
            [void](New-Item -ItemType Directory -Path $outputDirectory -ErrorAction SilentlyContinue)
        }
    }
}

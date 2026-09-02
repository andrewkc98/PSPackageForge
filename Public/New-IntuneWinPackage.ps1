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
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
    }
    $exitCode = Invoke-IntuneWinAppUtil -IntuneWinAppUtilPath $resolution.IntuneWinAppUtilPath `
        -PackagePath $preflight.SourcePath -OutputPath $outputDirectory
    $result.ToolExitCode = [int]$exitCode
    if ([int]$exitCode -ne 0) {
        throw [System.ComponentModel.Win32Exception]::new(
            "IntuneWinAppUtil.exe failed with exit code $exitCode. No package artifact was accepted.")
    }
    $expectedName = 'Invoke-AppDeployToolkit.intunewin'
    $outputs = @(Get-ChildItem -LiteralPath $outputDirectory -Filter '*.intunewin' -File -ErrorAction SilentlyContinue)
    if ($outputs.Count -ne 1 -or
        -not [string]::Equals($outputs[0].Name, $expectedName, [System.StringComparison]::OrdinalIgnoreCase) -or
        $outputs[0].Length -le 0) {
        throw [System.IO.IOException]::new(
            "Expected exactly one non-empty $expectedName; found $($outputs.Count).")
    }
    $result.IntuneWinPath = $outputs[0].FullName
    $result.SHA256 = (Get-FileHash -LiteralPath $outputs[0].FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    $result.Status = 'Built'
    return [PSCustomObject]$result
}

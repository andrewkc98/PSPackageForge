function Write-PackageManifest {
    <#
        Writes the authoritative PackageManifest.json. All downstream renderers consume
        the same InstallerInfo and PackageSpec represented here.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [InstallerInfo] $InstallerInfo,

        [Parameter(Mandatory)]
        [PackageSpec] $PackageSpec,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath
    )

    $allFindings = [System.Collections.Generic.List[Finding]]::new()
    foreach ($finding in $InstallerInfo.Findings) { $allFindings.Add($finding) }
    foreach ($finding in $PackageSpec.BlockingFindings) {
        $duplicate = $allFindings | Where-Object { $_.Code -eq $finding.Code -and $_.Message -eq $finding.Message }
        if (-not $duplicate) { $allFindings.Add($finding) }
    }

    $installerManifest = $InstallerInfo.ToOrderedDictionary()
    # Manifests are designed to be committed as examples. Record the content-relative
    # staged filename rather than leaking the packaging workstation's absolute profile path.
    $installerManifest['Path'] = $InstallerInfo.FileName

    $manifest = [ordered] @{
        SchemaVersion  = $script:ManifestSchemaVersion
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Generator      = [ordered] @{
            Name                 = 'PSPackageForge'
            Version              = "$script:GeneratorVersion"
            RequiredPSADTVersion = $script:RequiredPSADTVersion
        }
        Installer      = $installerManifest
        PackageSpec    = $PackageSpec.ToOrderedDictionary()
        Findings       = @($allFindings | ForEach-Object { $_.ToOrderedDictionary() })
        Readiness      = $PackageSpec.Readiness.ToString()
    }

    $parent = Split-Path -Path $OutputPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        [void] (New-Item -ItemType Directory -Path $parent -Force)
    }

    if ($PSCmdlet.ShouldProcess($OutputPath, 'Write authoritative package manifest')) {
        $json = $manifest | ConvertTo-Json -Depth 20
        Set-Content -LiteralPath $OutputPath -Value $json -Encoding UTF8

        # Structural v1 validation: prove the emitted document round-trips as JSON.
        $null = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
        return Get-Item -LiteralPath $OutputPath
    }
}

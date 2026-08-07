function New-PackageDocument {
    <#
        .SYNOPSIS
            Renders PackageDocument.md from a PackageManifest.json.

        .DESCRIPTION
            A pure renderer over the manifest. It must not rediscover or reinterpret
            anything -- the manifest is authoritative (plan §5.4): every value in the
            document is read from the manifest, never recomputed. This is what lets future
            MECM/Intune renderers be renderers rather than rewrites.

            The document carries the explicit verify-before-deploying checklist, the warning
            about the WMI product-inventory class that must never be queried (doing so forces
            Windows Installer to reconfigure every installed MSI on the machine), the
            UpgradeCode-is-not-supersedence note, a wrapper-MSI uninstall warning when
            applicable, the ConfigMgr client logs worth citing, and the ConfigMgr/Intune
            detection-contract platform difference -- so a packager can review a scaffold in
            about two minutes.

            PackageDocument.md is written next to the supplied manifest, mirroring how
            PackageManifest.json sits in the scaffold's output root.

        .PARAMETER ManifestPath
            Path to an existing PackageManifest.json.

        .OUTPUTS
            PSPackageForge.DocumentRenderResult
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('PSPackageForge.DocumentRenderResult')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ManifestPath
    )

    $resolvedManifestPath = (Resolve-Path -LiteralPath $ManifestPath -ErrorAction Stop).ProviderPath
    $manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json

    $documentPath = Join-Path (Split-Path -Path $resolvedManifestPath -Parent) 'PackageDocument.md'

    if ($PSCmdlet.ShouldProcess($documentPath, 'Render PackageDocument.md')) {
        $content = ConvertTo-PackageDocumentContent -Manifest $manifest
        Set-Content -LiteralPath $documentPath -Value $content -Encoding UTF8

        [PSCustomObject] @{
            PSTypeName   = 'PSPackageForge.DocumentRenderResult'
            ManifestPath = $resolvedManifestPath
            DocumentPath = (Resolve-Path -LiteralPath $documentPath).ProviderPath
        }
    }
}

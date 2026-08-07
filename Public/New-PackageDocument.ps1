function New-PackageDocument {
    <#
        .SYNOPSIS
            Renders PackageDocument.md from a PackageManifest.json.

        .DESCRIPTION
            A pure renderer over the manifest. It must not rediscover or reinterpret
            anything -- the manifest is authoritative (plan §5.4). The document carries the
            explicit verify-before-deploying checklist that makes the scaffold reviewable
            in about two minutes.

            NOT YET IMPLEMENTED -- build order step 8.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub. The parameter surface is the published contract; the body arrives in build order step 8.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ManifestPath
    )

    if ($PSCmdlet.ShouldProcess($ManifestPath, 'Render PackageDocument.md')) {
        throw [System.NotImplementedException]::new('New-PackageDocument is implemented in build order step 8.')
    }
}

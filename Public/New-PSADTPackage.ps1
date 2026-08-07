function New-PSADTPackage {
    <#
        .SYNOPSIS
            Generates a PSAppDeployToolkit v4 package from a resolved PackageSpec.

        .DESCRIPTION
            PSADT v4 only, via a pinned New-ADTTemplate. PSPackageForge fills the
            deployment sections of the natively generated template rather than shipping
            its own copy of one, and fails clearly if the pinned version is unavailable
            instead of rendering against an unknown template (plan §10.14).

            NOT YET IMPLEMENTED -- build order step 14.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub. The parameter surface is the published contract; the body arrives in build order step 14.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath
    )

    if ($PSCmdlet.ShouldProcess($OutputPath, 'Generate PSADT v4 package')) {
        throw [System.NotImplementedException]::new('New-PSADTPackage is implemented in build order step 14.')
    }
}

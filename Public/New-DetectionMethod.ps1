function New-DetectionMethod {
    <#
        .SYNOPSIS
            Produces a detection spec and renders Detect-Application.ps1.

        .DESCRIPTION
            One contract serves both MECM and Intune (plan §7.1): exit 0 with output means
            detected, exit 0 with no output means not detected, and a non-zero exit means
            the detection mechanism itself failed.

            NOT YET IMPLEMENTED -- build order step 7.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub. The parameter surface is the published contract; the body arrives in build order step 7.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath
    )

    if ($PSCmdlet.ShouldProcess($OutputPath, 'Generate Detect-Application.ps1')) {
        throw [System.NotImplementedException]::new('New-DetectionMethod is implemented in build order step 7.')
    }
}

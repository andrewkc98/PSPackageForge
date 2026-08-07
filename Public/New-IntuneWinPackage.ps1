function New-IntuneWinPackage {
    <#
        .SYNOPSIS
            Emits Build-IntuneWin.ps1 and runs IntuneWinAppUtil.exe when it can be located.

        .DESCRIPTION
            Tool resolution order: -IntuneWinAppUtilPath, then the configured path, then
            PATH, and otherwise build instructions only. PSPackageForge never downloads
            tooling automatically (plan §10.15).

            NOT YET IMPLEMENTED -- build order step 15.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub. The parameter surface is the published contract; the body arrives in build order step 15.')]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath
    )

    if ($PSCmdlet.ShouldProcess($OutputPath, 'Generate .intunewin package')) {
        throw [System.NotImplementedException]::new('New-IntuneWinPackage is implemented in build order step 15.')
    }
}

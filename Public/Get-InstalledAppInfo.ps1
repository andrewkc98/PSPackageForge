function Get-InstalledAppInfo {
    <#
        .SYNOPSIS
            Reference-machine discovery. Run where the application IS installed and export
            JSON for New-PackageScaffold -DiscoveryData.

        .DESCRIPTION
            For EXE installers there is no offline path to the real uninstall string -- at
            scaffold time the application is not installed. This is the KiCad case that
            motivated the project (plan §6).

            NOT YET IMPLEMENTED -- build order step 10.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub. The parameter surface is the published contract; the body arrives in build order step 10.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DisplayNameLike
    )

    throw [System.NotImplementedException]::new('Get-InstalledAppInfo is implemented in build order step 10.')
}

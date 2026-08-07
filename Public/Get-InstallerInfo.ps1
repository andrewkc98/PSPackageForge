function Get-InstallerInfo {
    <#
        .SYNOPSIS
            Identifies an installer and gathers evidence about it. Usable standalone.

        .DESCRIPTION
            Answers "what is this file?" and nothing else. Deployment decisions -- install
            command, uninstall command, context, detection -- are the job of the
            PackageSpec resolver, and keeping them apart is what stops a discovered value
            silently becoming a deployment choice (plan §2).

            NOT YET IMPLEMENTED -- build order step 4/5.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Stub. The parameter surface is the published contract; the body arrives in build order step 4.')]
    [CmdletBinding()]
    [OutputType([InstallerInfo])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    process {
        throw [System.NotImplementedException]::new('Get-InstallerInfo is implemented in build order step 4.')
    }
}

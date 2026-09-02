function Invoke-IntuneWinAppUtil {
    <#
        Invoke the already-resolved Win32 Content Prep Tool. Resolution and all
        package validation belong to the caller; this function is only the process seam.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [Alias('ToolPath')]
        [ValidateNotNullOrEmpty()]
        [string] $IntuneWinAppUtilPath,

        [Parameter(Mandatory)]
        [Alias('SourcePath')]
        [ValidateNotNullOrEmpty()]
        [string] $PackagePath,

        [Parameter(Mandatory)]
        [Alias('IntuneWinPath')]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath
    )

    $arguments = @(
        '-c', $PackagePath,
        '-s', 'Invoke-AppDeployToolkit.exe',
        '-o', $OutputPath,
        '-q'
    )
    $workingDirectory = Split-Path -Parent $PackagePath
    $process = Start-Process -FilePath $IntuneWinAppUtilPath -ArgumentList $arguments `
        -WorkingDirectory $workingDirectory -Wait -PassThru
    return [int] $process.ExitCode
}

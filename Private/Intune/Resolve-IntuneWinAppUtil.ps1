function Resolve-IntuneWinAppUtil {
    <#
        Resolve the locally available Microsoft Win32 Content Prep Tool.
        Resolution is deliberately local-only; this function never downloads or installs it.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [Alias('IntuneWinAppUtilPath')]
        [AllowNull()]
        [string] $ExplicitPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    )

    function ConvertTo-ResolutionResult {
        param(
            [bool] $Available,
            [AllowNull()] [string] $Path,
            [string] $Source,
            [object[]] $Findings
        )

        [pscustomobject]@{
            ToolAvailable       = $Available
            Available           = $Available
            IntuneWinAppUtilPath = $Path
            Path                = $Path
            Source              = $Source
            Findings            = @($Findings)
        }
    }

    function Resolve-ExistingLeaf {
        param([Parameter(Mandatory)][string] $Candidate)

        $item = Get-Item -LiteralPath $Candidate -ErrorAction SilentlyContinue
        if ($null -eq $item -or $item.PSIsContainer) { return $null }
        return $item.FullName
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolvedExplicit = Resolve-ExistingLeaf -Candidate $ExplicitPath
        if ($null -eq $resolvedExplicit) {
            throw [System.IO.FileNotFoundException]::new(
                "The explicitly supplied IntuneWinAppUtilPath '$ExplicitPath' is not an existing leaf file.")
        }

        return ConvertTo-ResolutionResult -Available $true -Path $resolvedExplicit -Source 'Explicit' -Findings @()
    }

    $settingsPath = Join-Path -Path $RepositoryRoot -ChildPath 'Config/settings.psd1'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Import-PowerShellDataFile -LiteralPath $settingsPath -ErrorAction Stop
        }
        catch {
            return ConvertTo-ResolutionResult -Available $false -Path $null -Source 'Configured' -Findings @(
                (New-ForgeFinding -Severity Blocking -Code INTUNEWINAPPUTIL_CONFIG_INVALID -Field IntuneWinAppUtilPath `
                    -Message ("Could not read repository settings '{0}': {1}" -f $settingsPath, $_.Exception.Message)))
        }

        $configured = $null
        if ($settings -is [System.Collections.IDictionary] -and $settings.Contains('IntuneWinAppUtilPath')) {
            $configured = $settings['IntuneWinAppUtilPath']
        }
        elseif ($null -ne $settings -and $null -ne $settings.PSObject.Properties['IntuneWinAppUtilPath']) {
            $configured = $settings.IntuneWinAppUtilPath
        }
        if ($null -ne $configured -and -not ($configured -is [string])) {
            return ConvertTo-ResolutionResult -Available $false -Path $null -Source 'Configured' -Findings @(
                (New-ForgeFinding -Severity Blocking -Code INTUNEWINAPPUTIL_CONFIG_INVALID -Field IntuneWinAppUtilPath `
                    -Message "Config/settings.psd1 IntuneWinAppUtilPath must be a string containing an existing leaf file."))
        }
        if (-not [string]::IsNullOrWhiteSpace([string] $configured)) {
            $configuredCandidate = [string] $configured
            if (-not [System.IO.Path]::IsPathRooted($configuredCandidate)) {
                $configuredCandidate = Join-Path -Path (Split-Path -Parent $settingsPath) -ChildPath $configuredCandidate
            }
            $resolvedConfigured = Resolve-ExistingLeaf -Candidate $configuredCandidate
            if ($null -eq $resolvedConfigured) {
                return ConvertTo-ResolutionResult -Available $false -Path $null -Source 'Configured' -Findings @(
                    (New-ForgeFinding -Severity Blocking -Code INTUNEWINAPPUTIL_CONFIG_INVALID -Field IntuneWinAppUtilPath `
                        -Message ("Configured IntuneWinAppUtilPath '{0}' is not an existing leaf file." -f $configuredCandidate)))
            }

            return ConvertTo-ResolutionResult -Available $true -Path $resolvedConfigured -Source 'Configured' -Findings @()
        }
    }

    $pathCommands = @(Get-Command -Name 'IntuneWinAppUtil.exe' -CommandType Application -All -ErrorAction SilentlyContinue)
    $pathCandidates = @($pathCommands | ForEach-Object {
            if ($_.Path) { Resolve-ExistingLeaf -Candidate $_.Path }
            elseif ($_.Source) { Resolve-ExistingLeaf -Candidate $_.Source }
        } | Where-Object { $_ } | Sort-Object -Unique)

    if ($pathCandidates.Count -eq 1) {
        return ConvertTo-ResolutionResult -Available $true -Path $pathCandidates[0] -Source 'PATH' -Findings @()
    }
    if ($pathCandidates.Count -gt 1) {
        return ConvertTo-ResolutionResult -Available $false -Path $null -Source 'PATH' -Findings @(
            (New-ForgeFinding -Severity Blocking -Code INTUNEWINAPPUTIL_AMBIGUOUS -Field IntuneWinAppUtilPath `
                -Message ("Multiple IntuneWinAppUtil.exe files were found on PATH: {0}" -f ($pathCandidates -join ', '))))
    }

    return ConvertTo-ResolutionResult -Available $false -Path $null -Source 'Unavailable' -Findings @(
        (New-ForgeFinding -Severity Warning -Code INTUNEWINAPPUTIL_UNAVAILABLE -Field IntuneWinAppUtilPath `
            -Message 'IntuneWinAppUtil.exe was not found from an explicit path, repository settings, or PATH. PSPackageForge never downloads tooling automatically.'))
}

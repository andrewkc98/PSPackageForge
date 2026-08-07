function New-DetectionMethod {
    <#
        .SYNOPSIS
            Produces a detection spec and renders Detect-Application.ps1.

        .DESCRIPTION
            One contract serves both MECM and Intune (plan §7.1): exit 0 with output means
            detected, exit 0 with no output means not detected, and a non-zero exit means
            the detection mechanism itself failed.

            The supplied DetectionSpec is already resolved; this command is a pure renderer
            and does not rediscover application information.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('PSPackageForge.DetectionRenderResult')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNull()]
        [object] $DetectionSpec,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath
    )

    process {
        if ($DetectionSpec -isnot [DetectionSpec]) {
            throw [System.ArgumentException]::new(
                "DetectionSpec must be a PSPackageForge DetectionSpec; got '$($DetectionSpec.GetType().FullName)'.",
                'DetectionSpec')
        }

        $scriptContent = ConvertTo-DetectionScript -DetectionSpec $DetectionSpec
        $scriptPath = if ([System.IO.Path]::GetExtension($OutputPath) -eq '.ps1') {
            $OutputPath
        }
        else {
            Join-Path $OutputPath 'Detect-Application.ps1'
        }

        if ($PSCmdlet.ShouldProcess($scriptPath, 'Generate detection script')) {
            $parent = Split-Path -Path $scriptPath -Parent
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                [void] (New-Item -ItemType Directory -Path $parent -Force)
            }
            Set-Content -LiteralPath $scriptPath -Value $scriptContent -Encoding UTF8

            [PSCustomObject] @{
                PSTypeName    = 'PSPackageForge.DetectionRenderResult'
                DetectionSpec = $DetectionSpec
                ScriptPath    = (Resolve-Path -LiteralPath $scriptPath).ProviderPath
                ScriptContent = $scriptContent
            }
        }
    }
}

function Resolve-PSADTTemplateCommand {
    <#
        .SYNOPSIS
            Resolves the pinned PSAppDeployToolkit New-ADTTemplate command.

        .DESCRIPTION
            Resolution is intentionally local-only. An explicit module manifest wins;
            otherwise the exact required version must already be installed. PSPackageForge
            never downloads or upgrades PSADT and never falls forward to another version.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.CommandInfo])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [Version] $RequiredVersion,

        [Parameter()]
        [AllowNull()]
        [string] $ModulePath
    )

    $moduleToImport = $null
    if (-not [string]::IsNullOrWhiteSpace($ModulePath)) {
        $resolvedModulePath = (Resolve-Path -LiteralPath $ModulePath -ErrorAction Stop).ProviderPath
        if ([System.IO.Path]::GetExtension($resolvedModulePath) -ne '.psd1') {
            throw [System.IO.InvalidDataException]::new(
                "PSADTModulePath must name the PSAppDeployToolkit.psd1 module manifest, not '$resolvedModulePath'.")
        }

        $moduleData = Import-PowerShellDataFile -Path $resolvedModulePath
        $moduleVersion = [Version] $moduleData.ModuleVersion
        if ($moduleVersion -ne $RequiredVersion) {
            throw [System.IO.InvalidDataException]::new(
                "PSADTModulePath provides version $moduleVersion, but PackageManifest.json requires exactly $RequiredVersion.")
        }
        $moduleToImport = $resolvedModulePath
    }
    else {
        $available = @(Get-Module -ListAvailable -Name 'PSAppDeployToolkit' |
            Where-Object { $_.Version -eq $RequiredVersion } |
            Sort-Object -Property ModuleBase)
        if ($available.Count -eq 0) {
            throw [System.IO.FileNotFoundException]::new(
                "PSAppDeployToolkit $RequiredVersion with New-ADTTemplate is required but is not installed. Install that exact version or supply -PSADTModulePath. PSPackageForge never downloads tooling automatically.")
        }
        $moduleToImport = $available[0].Path
    }

    try {
        Import-Module -Name $moduleToImport -Force -ErrorAction Stop
    }
    catch {
        throw [System.InvalidOperationException]::new(
            "PSAppDeployToolkit $RequiredVersion could not be imported from '$moduleToImport'.", $_.Exception)
    }

    $commands = @(Get-Command -Name 'New-ADTTemplate' -CommandType Function -All -ErrorAction SilentlyContinue |
        Where-Object {
            $null -ne $_.Module -and
            $_.Module.Name -eq 'PSAppDeployToolkit' -and
            $_.Module.Version -eq $RequiredVersion
        })
    if ($commands.Count -ne 1) {
        throw [System.InvalidOperationException]::new(
            "PSAppDeployToolkit $RequiredVersion did not expose exactly one New-ADTTemplate function.")
    }

    foreach ($parameterName in @('Destination', 'Name', 'Version', 'PassThru')) {
        if (-not $commands[0].Parameters.ContainsKey($parameterName)) {
            throw [System.InvalidOperationException]::new(
                "New-ADTTemplate from PSAppDeployToolkit $RequiredVersion does not expose the required -$parameterName parameter.")
        }
    }

    return $commands[0]
}

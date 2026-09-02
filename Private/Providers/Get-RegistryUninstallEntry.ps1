function Get-ForgePortablePathRoot {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    $programFiles64 = [Environment]::GetEnvironmentVariable('ProgramW6432')
    if ([string]::IsNullOrWhiteSpace($programFiles64)) {
        $programFiles64 = [Environment]::GetEnvironmentVariable('ProgramFiles')
    }
    $commonFiles64 = [Environment]::GetEnvironmentVariable('CommonProgramW6432')
    if ([string]::IsNullOrWhiteSpace($commonFiles64)) {
        $commonFiles64 = [Environment]::GetEnvironmentVariable('CommonProgramFiles')
    }

    @(
        [PSCustomObject] @{ Token = '%ProgramFiles(x86)%';       Value = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)') }
        [PSCustomObject] @{ Token = '%ProgramFiles%';            Value = $programFiles64 }
        [PSCustomObject] @{ Token = '%CommonProgramFiles(x86)%'; Value = [Environment]::GetEnvironmentVariable('CommonProgramFiles(x86)') }
        [PSCustomObject] @{ Token = '%CommonProgramFiles%';      Value = $commonFiles64 }
        [PSCustomObject] @{ Token = '%ProgramData%';             Value = [Environment]::GetEnvironmentVariable('ProgramData') }
        [PSCustomObject] @{ Token = '%LOCALAPPDATA%';            Value = [Environment]::GetEnvironmentVariable('LocalAppData') }
        [PSCustomObject] @{ Token = '%APPDATA%';                 Value = [Environment]::GetEnvironmentVariable('AppData') }
        [PSCustomObject] @{ Token = '%USERPROFILE%';             Value = [Environment]::GetEnvironmentVariable('UserProfile') }
        [PSCustomObject] @{ Token = '%PUBLIC%';                  Value = [Environment]::GetEnvironmentVariable('Public') }
        [PSCustomObject] @{ Token = '%SystemRoot%';              Value = [Environment]::GetEnvironmentVariable('SystemRoot') }
        [PSCustomObject] @{ Token = '%TEMP%';                    Value = [Environment]::GetEnvironmentVariable('TEMP') }
        [PSCustomObject] @{ Token = '%SystemDrive%';             Value = [Environment]::GetEnvironmentVariable('SystemDrive') }
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Value) } |
        Sort-Object -Property @{ Expression = { $_.Value.Length }; Descending = $true }
}


function Expand-ForgePortablePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    $expanded = $Value
    foreach ($root in @(Get-ForgePortablePathRoot)) {
        $expanded = $expanded.Replace($root.Token, $root.Value)
    }
    return [Environment]::ExpandEnvironmentVariables($expanded)
}


function ConvertTo-ForgePortablePath {
    <#
        Replaces machine/user-specific Windows roots with the environment-token form used
        throughout PSPackageForge. The function accepts complete command lines as well as
        paths; replacements therefore preserve an existing quoted command's structure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }

    # A remote host/share name is machine-specific data and has no portable token in the
    # v1 contract. Suppress the entire value; the converter will emit a finding instead.
    if ($Value -match '(?i)(^|["\s])\\\\[^\\\s]+\\') { return $null }

    $portable = $Value
    foreach ($root in @(Get-ForgePortablePathRoot)) {
        $rootPattern = [regex]::Escape($root.Value.TrimEnd([char] 92)) + '(?=\\|/|["\s,]|$)'
        $portable = [regex]::Replace(
            $portable,
            $rootPattern,
            $root.Token,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    # A different user's literal profile root is neither portable nor safe to export.
    # The current profile was replaced above; suppress any profile name that remains.
    if ($portable -match '(?i)[A-Z]:\\Users\\(?!Public(?:\\|$)|Default(?: User)?(?:\\|$))[^\\]+(?:\\|$)') {
        return $null
    }

    return $portable
}


function Get-RegistryUninstallEntry {
    <#
        .SYNOPSIS
            Reads one explicit uninstall-registry hive and view.

        .DESCRIPTION
            This is the mock boundary for reference-machine discovery. It deliberately
            uses Microsoft.Win32.RegistryKey rather than a provider drive, so callers
            choose the registry view instead of inheriting the host process bitness.

            Returned rows contain only the relative subkey name and the small allow-list
            of values discovery understands. Paths are tokenized before leaving this
            boundary; registry handles are always disposed in finally blocks.
    #>
    [CmdletBinding()]
    [OutputType('PSPackageForge.RegistryUninstallEntry')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('LocalMachine', 'CurrentUser')]
        [string] $Hive,

        [Parameter(Mandatory)]
        [ValidateSet('Registry32', 'Registry64')]
        [string] $View
    )

    $registryHive = switch ($Hive) {
        'LocalMachine' { [Microsoft.Win32.RegistryHive]::LocalMachine }
        'CurrentUser'  { [Microsoft.Win32.RegistryHive]::CurrentUser }
    }

    $registryView = switch ($View) {
        'Registry32' { [Microsoft.Win32.RegistryView]::Registry32 }
        'Registry64' { [Microsoft.Win32.RegistryView]::Registry64 }
    }

    $baseKey = $null
    $uninstallKey = $null

    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($registryHive, $registryView)
        $uninstallKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', $false)
        if ($null -eq $uninstallKey) { return }

        foreach ($subKeyName in $uninstallKey.GetSubKeyNames()) {
            $entryKey = $null
            try {
                $entryKey = $uninstallKey.OpenSubKey($subKeyName, $false)
                if ($null -eq $entryKey) { continue }

                $getString = {
                    param([string] $name)
                    $raw = $entryKey.GetValue(
                        $name,
                        $null,
                        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if ($null -eq $raw) { return $null }
                    return [string] $raw
                }

                $getInteger = {
                    param([string] $name)
                    $raw = $entryKey.GetValue($name, $null)
                    if ($null -eq $raw) { return 0 }
                    $parsed = 0
                    if ([int]::TryParse([string] $raw, [ref] $parsed)) { return $parsed }
                    return 0
                }

                $installLocation = & $getString 'InstallLocation'
                $quietUninstall  = & $getString 'QuietUninstallString'
                $uninstall       = & $getString 'UninstallString'
                $displayIcon     = & $getString 'DisplayIcon'

                [PSCustomObject] [ordered] @{
                    PSTypeName           = 'PSPackageForge.RegistryUninstallEntry'
                    Hive                 = $Hive
                    View                 = $View
                    SubKey               = ([regex]::Replace($subKeyName, '[\x00-\x1F\x7F]', ''))
                    DisplayName          = & $getString 'DisplayName'
                    Publisher            = & $getString 'Publisher'
                    DisplayVersion       = & $getString 'DisplayVersion'
                    InstallLocation      = if ($installLocation) { ConvertTo-ForgePortablePath -Value $installLocation } else { $null }
                    QuietUninstallString = if ($quietUninstall) { ConvertTo-ForgePortablePath -Value $quietUninstall } else { $null }
                    UninstallString      = if ($uninstall) { ConvertTo-ForgePortablePath -Value $uninstall } else { $null }
                    DisplayIcon          = if ($displayIcon) { ConvertTo-ForgePortablePath -Value $displayIcon } else { $null }
                    WindowsInstaller     = & $getInteger 'WindowsInstaller'
                    SystemComponent      = & $getInteger 'SystemComponent'
                }
            }
            catch {
                [PSCustomObject] [ordered] @{
                    PSTypeName = 'PSPackageForge.RegistryUninstallEntryReadError'
                    Hive       = $Hive
                    View       = $View
                    SubKey     = ([regex]::Replace($subKeyName, '[\x00-\x1F\x7F]', ''))
                    ReadError  = $true
                }
            }
            finally {
                if ($null -ne $entryKey) { $entryKey.Dispose() }
            }
        }
    }
    finally {
        if ($null -ne $uninstallKey) { $uninstallKey.Dispose() }
        if ($null -ne $baseKey) { $baseKey.Dispose() }
    }
}

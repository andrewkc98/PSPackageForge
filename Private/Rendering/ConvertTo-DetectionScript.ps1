function ConvertTo-PowerShellSingleQuotedLiteral {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [string] $Value
    )

    if ($null -eq $Value) { return '$null' }
    return "'{0}'" -f ($Value -replace "'", "''")
}


function ConvertTo-DetectionScript {
    <#
        Renders exactly one v1 DetectionSpec. The generated contract is:
          detected -> exit 0 + non-empty STDOUT
          absent   -> exit 0 + empty STDOUT
          failure  -> non-zero + STDERR
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [DetectionSpec] $DetectionSpec
    )

    $commonHeader = @'
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

'@

    switch ($DetectionSpec.Kind) {
        ([DetectionKind]::File) {
            $template = @'
try {
    $directory = [Environment]::ExpandEnvironmentVariables(__RULE_PATH__)
    $target = Join-Path -Path $directory -ChildPath __RULE_FILE__

    if (__RULE_WILDCARD__) {
        $candidate = Get-ChildItem -Path $target -File -ErrorAction SilentlyContinue |
            Sort-Object -Property FullName |
            Select-Object -First 1
    }
    else {
        $candidate = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue
    }

    if ($null -eq $candidate) { exit 0 }

    $detected = $false
    switch (__RULE_OPERATOR__) {
        'Exists' {
            $detected = $true
        }
        'Exact' {
            $actual = $candidate.VersionInfo.FileVersion
            if ([string]::IsNullOrWhiteSpace($actual)) {
                throw "The detection target '$($candidate.FullName)' has no file version."
            }
            $detected = $actual -eq __RULE_VALUE__
        }
        'GreaterOrEqual' {
            $actual = $candidate.VersionInfo.FileVersion
            if ([string]::IsNullOrWhiteSpace($actual)) {
                throw "The detection target '$($candidate.FullName)' has no file version."
            }
            $actualVersion   = [version]::Parse($actual)
            $requiredVersion = [version]::Parse(__RULE_VALUE__)
            $detected = $actualVersion -ge $requiredVersion
        }
        default {
            throw "Unsupported detection operator: __RULE_OPERATOR__"
        }
    }

    if ($detected) { Write-Output "Detected: $($candidate.FullName)" }
    exit 0
}
catch {
    [Console]::Error.WriteLine("Detection failed: $($_.Exception.Message)")
    exit 2
}
'@
            $rendered = $template.Replace('__RULE_PATH__', (ConvertTo-PowerShellSingleQuotedLiteral $DetectionSpec.Path))
            $rendered = $rendered.Replace('__RULE_FILE__', (ConvertTo-PowerShellSingleQuotedLiteral $DetectionSpec.FileName))
            $rendered = $rendered.Replace('__RULE_WILDCARD__', $(if ($DetectionSpec.UsesWildcardPath) { '$true' } else { '$false' }))
            $rendered = $rendered.Replace('__RULE_OPERATOR__', (ConvertTo-PowerShellSingleQuotedLiteral $DetectionSpec.Operator.ToString()))
            $rendered = $rendered.Replace('__RULE_VALUE__', (ConvertTo-PowerShellSingleQuotedLiteral $DetectionSpec.Value))
            return $commonHeader + $rendered
        }

        ([DetectionKind]::Registry) {
            $template = @'
try {
    $keyPath = __RULE_KEY__
    $valueName = __RULE_VALUE_NAME__
    $viewName = __RULE_VIEW__

    if ($keyPath -match '^(HKLM:|HKEY_LOCAL_MACHINE\\)') {
        $hive = [Microsoft.Win32.RegistryHive]::LocalMachine
        $subKey = $keyPath -replace '^(HKLM:\\?|HKEY_LOCAL_MACHINE\\)', ''
    }
    elseif ($keyPath -match '^(HKCU:|HKEY_CURRENT_USER\\)') {
        $hive = [Microsoft.Win32.RegistryHive]::CurrentUser
        $subKey = $keyPath -replace '^(HKCU:\\?|HKEY_CURRENT_USER\\)', ''
    }
    else {
        throw "Registry detection requires an explicit HKLM or HKCU key path."
    }

    $view = switch ($viewName) {
        'Registry32' { [Microsoft.Win32.RegistryView]::Registry32 }
        'Registry64' { [Microsoft.Win32.RegistryView]::Registry64 }
        default      { [Microsoft.Win32.RegistryView]::Default }
    }

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
    try { $key = $base.OpenSubKey($subKey) }
    finally { $base.Dispose() }

    if ($null -eq $key) { exit 0 }
    try {
        $actual = if ([string]::IsNullOrEmpty($valueName)) { $key.GetValue('') } else { $key.GetValue($valueName) }
    }
    finally { $key.Dispose() }

    $detected = switch (__RULE_OPERATOR__) {
        'Exists'         { $null -ne $actual }
        'Exact'          { "$actual" -eq __RULE_VALUE__ }
        'GreaterOrEqual' { [version]::Parse("$actual") -ge [version]::Parse(__RULE_VALUE__) }
        default          { throw "Unsupported detection operator: __RULE_OPERATOR__" }
    }

    if ($detected) { Write-Output "Detected: registry value present" }
    exit 0
}
catch {
    [Console]::Error.WriteLine("Detection failed: $($_.Exception.Message)")
    exit 2
}
'@
            $rendered = $template.Replace('__RULE_KEY__', (ConvertTo-PowerShellSingleQuotedLiteral $DetectionSpec.KeyPath))
            $rendered = $rendered.Replace('__RULE_VALUE_NAME__', (ConvertTo-PowerShellSingleQuotedLiteral $DetectionSpec.ValueName))
            $rendered = $rendered.Replace('__RULE_VIEW__', (ConvertTo-PowerShellSingleQuotedLiteral $DetectionSpec.RegistryView.ToString()))
            $rendered = $rendered.Replace('__RULE_OPERATOR__', (ConvertTo-PowerShellSingleQuotedLiteral $DetectionSpec.Operator.ToString()))
            $rendered = $rendered.Replace('__RULE_VALUE__', (ConvertTo-PowerShellSingleQuotedLiteral $DetectionSpec.Value))
            return $commonHeader + $rendered
        }

        ([DetectionKind]::MsiProductCode) {
            $template = @'
try {
    $productCode = __PRODUCT_CODE__
    $subKey = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"
    $detected = $false

    foreach ($hive in @(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryHive]::CurrentUser
    )) {
        foreach ($view in @(
            [Microsoft.Win32.RegistryView]::Registry64,
            [Microsoft.Win32.RegistryView]::Registry32
        )) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
            try { $key = $base.OpenSubKey($subKey) }
            finally { $base.Dispose() }
            if ($null -ne $key) {
                $key.Dispose()
                $detected = $true
                break
            }
        }
        if ($detected) { break }
    }

    if ($detected) { Write-Output "Detected: MSI product $productCode" }
    exit 0
}
catch {
    [Console]::Error.WriteLine("Detection failed: $($_.Exception.Message)")
    exit 2
}
'@
            return $commonHeader + $template.Replace('__PRODUCT_CODE__', (ConvertTo-PowerShellSingleQuotedLiteral $DetectionSpec.Value))
        }
    }

    throw [System.NotSupportedException]::new("Unsupported detection kind: $($DetectionSpec.Kind)")
}

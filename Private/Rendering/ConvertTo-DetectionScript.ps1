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
        try {
            # Enumerate every match in a stable order. A wildcard rule is an any-match
            # rule; selecting one candidate makes the result depend on unrelated names.
            $candidates = @(Get-ChildItem -Path $target -File -ErrorAction Stop |
                Sort-Object -Property FullName)
        }
        catch {
            if ($_.Exception -is [System.Management.Automation.ItemNotFoundException] -or
                $_.CategoryInfo.Category -eq 'ObjectNotFound') { exit 0 }
            throw
        }
    }
    else {
        try {
            $candidates = @(Get-Item -LiteralPath $target -ErrorAction Stop)
        }
        catch {
            if ($_.Exception -is [System.Management.Automation.ItemNotFoundException] -or
                $_.CategoryInfo.Category -eq 'ObjectNotFound') { exit 0 }
            throw
        }
    }

    if ($candidates.Count -eq 0) { exit 0 }

    foreach ($candidate in $candidates) {
        try {
            $detected = switch (__RULE_OPERATOR__) {
                'Exists' { $true }
                'Exact' {
                    # Compare the binary four-part version from the FileXPart properties,
                    # rather than the arbitrary FileVersion string resource.
                    $vi = $candidate.VersionInfo
                    $actual = [version]::new($vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart)
                    if ($actual -eq [version]::new(0, 0, 0, 0) -and [string]::IsNullOrWhiteSpace($vi.FileVersion)) {
                        throw "The detection target '$($candidate.FullName)' has no file version."
                    }
                    $requiredRaw = [version]::Parse(__RULE_VALUE__)
                    $required = [version]::new($requiredRaw.Major, $requiredRaw.Minor, [Math]::Max($requiredRaw.Build, 0), [Math]::Max($requiredRaw.Revision, 0))
                    $actual -eq $required
                }
                'GreaterOrEqual' {
                    $vi = $candidate.VersionInfo
                    $actual = [version]::new($vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart)
                    if ($actual -eq [version]::new(0, 0, 0, 0) -and [string]::IsNullOrWhiteSpace($vi.FileVersion)) {
                        throw "The detection target '$($candidate.FullName)' has no file version."
                    }
                    $requiredRaw = [version]::Parse(__RULE_VALUE__)
                    $required = [version]::new($requiredRaw.Major, $requiredRaw.Minor, [Math]::Max($requiredRaw.Build, 0), [Math]::Max($requiredRaw.Revision, 0))
                    $actual -ge $required
                }
                default { throw "Unsupported detection operator: __RULE_OPERATOR__" }
            }

            if ($detected) {
                Write-Output "Detected: $($candidate.FullName)"
                exit 0
            }
        }
        catch {
            # A metadata failure is definitive unless an earlier candidate already satisfied
            # the rule. Satisfied candidates return immediately above.
            throw
        }
    }

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

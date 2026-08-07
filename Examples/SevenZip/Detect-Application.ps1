#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    $directory = [Environment]::ExpandEnvironmentVariables('%ProgramFiles%\7-Zip')
    $target = Join-Path -Path $directory -ChildPath '7z.exe'

    if ($false) {
        $candidate = Get-ChildItem -Path $target -File -ErrorAction SilentlyContinue |
            Sort-Object -Property FullName |
            Select-Object -First 1
    }
    else {
        $candidate = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue
    }

    if ($null -eq $candidate) { exit 0 }

    $detected = $false
    switch ('Exact') {
        'Exists' {
            $detected = $true
        }
        'Exact' {
            $actual = $candidate.VersionInfo.FileVersion
            if ([string]::IsNullOrWhiteSpace($actual)) {
                throw "The detection target '$($candidate.FullName)' has no file version."
            }
            $detected = $actual -eq '26.2.0.0'
        }
        'GreaterOrEqual' {
            $actual = $candidate.VersionInfo.FileVersion
            if ([string]::IsNullOrWhiteSpace($actual)) {
                throw "The detection target '$($candidate.FullName)' has no file version."
            }
            $actualVersion   = [version]::Parse($actual)
            $requiredVersion = [version]::Parse('26.2.0.0')
            $detected = $actualVersion -ge $requiredVersion
        }
        default {
            throw "Unsupported detection operator: 'Exact'"
        }
    }

    if ($detected) { Write-Output "Detected: $($candidate.FullName)" }
    exit 0
}
catch {
    [Console]::Error.WriteLine("Detection failed: $($_.Exception.Message)")
    exit 2
}

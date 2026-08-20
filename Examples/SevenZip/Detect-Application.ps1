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
            # The recorded rule value is the MSI File table's binary dotted-quad version, not
            # the arbitrary FileVersion string resource -- those two routinely disagree (e.g.
            # binary '23.1.0.0' vs string '23.1'). Build the on-disk binary version the same
            # way the rule value was recorded. FileVersionRaw is not guaranteed present on
            # 5.1, so the four Part properties are used instead.
            $vi = $candidate.VersionInfo
            $actual = [version]::new($vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart)
            if ($actual -eq [version]::new(0, 0, 0, 0) -and [string]::IsNullOrWhiteSpace($vi.FileVersion)) {
                throw "The detection target '$($candidate.FullName)' has no file version."
            }
            # [version] equality treats a missing component as -1, so '23.1' -ne '23.1.0.0'
            # even though they mean the same version. Pad the required value to four parts
            # before comparing; $actual is already four parts by construction above.
            $requiredRaw = [version]::Parse('26.2.0.0')
            $required = [version]::new($requiredRaw.Major, $requiredRaw.Minor, [Math]::Max($requiredRaw.Build, 0), [Math]::Max($requiredRaw.Revision, 0))
            $detected = $actual -eq $required
        }
        'GreaterOrEqual' {
            $vi = $candidate.VersionInfo
            $actual = [version]::new($vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart)
            if ($actual -eq [version]::new(0, 0, 0, 0) -and [string]::IsNullOrWhiteSpace($vi.FileVersion)) {
                throw "The detection target '$($candidate.FullName)' has no file version."
            }
            $requiredRaw = [version]::Parse('26.2.0.0')
            $required = [version]::new($requiredRaw.Major, $requiredRaw.Minor, [Math]::Max($requiredRaw.Build, 0), [Math]::Max($requiredRaw.Revision, 0))
            $detected = $actual -ge $required
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

function Read-PortableExecutableData {
    [CmdletBinding()]
    [OutputType('PSPackageForge.PortableExecutableMetadata')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [string[]] $AsciiMarkers = @(),
        [string[]] $Utf16LEMarkers = @(),

        [ValidateRange(64, 1048576)]
        [int] $ChunkSize = 4096
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $stream = $null

    try {
        $stream = [System.IO.File]::Open($resolved, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)

        if ($stream.Length -lt 64) { throw "Portable executable '$resolved' is truncated before the DOS header is complete." }

        $dos = New-Object byte[] 64
        if ($stream.Read($dos, 0, $dos.Length) -ne $dos.Length) { throw "Portable executable '$resolved' could not be read." }
        if ($dos[0] -ne 0x4D -or $dos[1] -ne 0x5A) { throw "Portable executable '$resolved' does not begin with an MZ signature." }

        $peOffset = [BitConverter]::ToInt32($dos, 0x3C)
        if ($peOffset -lt 64 -or $peOffset -gt $stream.Length - 24) { throw "Portable executable '$resolved' has an invalid PE header offset ($peOffset)." }
        $stream.Position = $peOffset
        $signature = New-Object byte[] 4
        if ($stream.Read($signature, 0, 4) -ne 4 -or $signature[0] -ne 0x50 -or $signature[1] -ne 0x45 -or $signature[2] -ne 0 -or $signature[3] -ne 0) {
            throw "Portable executable '$resolved' has an invalid PE signature."
        }

        $coff = New-Object byte[] 20
        if ($stream.Read($coff, 0, 20) -ne 20) { throw "Portable executable '$resolved' is truncated in the COFF header." }
        $machine = [BitConverter]::ToUInt16($coff, 0)
        $sectionCount = [BitConverter]::ToUInt16($coff, 2)
        $optionalSize = [BitConverter]::ToUInt16($coff, 16)
        if ($sectionCount -lt 1 -or $sectionCount -gt 96) { throw "Portable executable '$resolved' has an impossible section count ($sectionCount)." }
        if ($optionalSize -lt 2 -or $optionalSize -gt 4096) { throw "Portable executable '$resolved' has an invalid optional-header size ($optionalSize)." }

        $optional = New-Object byte[] $optionalSize
        if ($stream.Read($optional, 0, $optionalSize) -ne $optionalSize) { throw "Portable executable '$resolved' is truncated in the optional header." }
        $magic = [BitConverter]::ToUInt16($optional, 0)
        if ($magic -ne 0x10B -and $magic -ne 0x20B) { throw "Portable executable '$resolved' has an unsupported optional-header magic (0x{0:X})." -f $magic }

        $sectionTableEnd = $stream.Position + (40L * $sectionCount)
        if ($sectionTableEnd -gt $stream.Length) { throw "Portable executable '$resolved' is truncated in the section headers." }
        $sectionNames = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $header = New-Object byte[] 40
            if ($stream.Read($header, 0, 40) -ne 40) { throw "Portable executable '$resolved' is truncated in section header $i." }
            $nameBytes = $header[0..7]
            $zero = [Array]::IndexOf($nameBytes, [byte]0)
            if ($zero -lt 0) { $zero = 8 }
            $name = [Text.Encoding]::ASCII.GetString($nameBytes, 0, $zero)
            if ([string]::IsNullOrWhiteSpace($name)) { throw "Portable executable '$resolved' contains an empty section name at index $i." }
            $sectionNames.Add($name)
            $rawSize = [BitConverter]::ToUInt32($header, 16)
            $rawOffset = [BitConverter]::ToUInt32($header, 20)
            if ($rawSize -gt 0 -and ([int64]$rawOffset + [int64]$rawSize -gt $stream.Length)) {
                throw "Portable executable '$resolved' has a section $name outside the file bounds."
            }
        }

        $architecture = switch ($machine) {
            0x014c { 'x86' }
            0x8664 { 'x64' }
            0xAA64 { 'Arm64' }
            default { 'Unknown' }
        }

        $ascii = @($AsciiMarkers | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique)
        $utf16 = @($Utf16LEMarkers | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique)
        $asciiBytes = @($ascii | ForEach-Object { ,([Text.Encoding]::ASCII.GetBytes($_)) })
        $utf16Bytes = @($utf16 | ForEach-Object { ,([Text.Encoding]::Unicode.GetBytes($_)) })
        $allBytes = @($asciiBytes + $utf16Bytes)
        $overlap = 0
        foreach ($bytes in $allBytes) { if ($bytes.Length -gt $overlap) { $overlap = $bytes.Length } }
        $overlap = [Math]::Max(0, $overlap - 1)
        $foundAscii = [System.Collections.Generic.List[string]]::new()
        $foundUtf16 = [System.Collections.Generic.List[string]]::new()
        if ($allBytes.Count -gt 0) {
            $stream.Position = 0
            $carry = New-Object byte[] 0
            $buffer = New-Object byte[] $ChunkSize
            while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $combined = New-Object byte[] ($carry.Length + $read)
                if ($carry.Length) { [Array]::Copy($carry, $combined, $carry.Length) }
                [Array]::Copy($buffer, 0, $combined, $carry.Length, $read)
                if ($ascii.Count -gt 0) {
                    foreach ($index in 0..($ascii.Count - 1)) {
                        if ($foundAscii -notcontains $ascii[$index] -and (Find-PortableMarker -Haystack $combined -Needle $asciiBytes[$index])) { $foundAscii.Add($ascii[$index]) }
                    }
                }
                if ($utf16.Count -gt 0) {
                    foreach ($index in 0..($utf16.Count - 1)) {
                        if ($foundUtf16 -notcontains $utf16[$index] -and (Find-PortableMarker -Haystack $combined -Needle $utf16Bytes[$index])) { $foundUtf16.Add($utf16[$index]) }
                    }
                }
                $keep = [Math]::Min($overlap, $combined.Length)
                $carry = if ($keep) { $combined[($combined.Length - $keep)..($combined.Length - 1)] } else { New-Object byte[] 0 }
            }
        }

        $version = [ordered]@{ FileVersion = $null; ProductVersion = $null; ProductName = $null; CompanyName = $null }
        try {
            $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($resolved)
            foreach ($key in @($version.Keys)) { if ($vi.$key) { $version[$key] = [string]$vi.$key } }
        } catch { $null = $_ }
        [PSCustomObject]@{ PSTypeName = 'PSPackageForge.PortableExecutableMetadata'; Path = $resolved; Machine = ('0x{0:X4}' -f $machine); Architecture = $architecture; SectionNames = @($sectionNames); AsciiMarkersFound = @($foundAscii); Utf16LEMarkersFound = @($foundUtf16); FileVersionInfo = [PSCustomObject]$version }
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}
function Find-PortableMarker {
    param([byte[]] $Haystack, [byte[]] $Needle)
    if ($Needle.Length -eq 0 -or $Needle.Length -gt $Haystack.Length) { return $false }
    for ($i = 0; $i -le $Haystack.Length - $Needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) { if ($Haystack[$i + $j] -ne $Needle[$j]) { $match = $false; break } }
        if ($match) { return $true }
    }
    return $false
}

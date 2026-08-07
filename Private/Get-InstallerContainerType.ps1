function Get-InstallerContainerType {
    <#
        .SYNOPSIS
            Determines what kind of file an installer actually is, from its content.

        .DESCRIPTION
            The extension is a hint, not an answer. A file named .msi that is really a
            renamed EXE would otherwise be handed to the MSI provider, which would fail with
            an opaque COM error instead of a useful finding.

            Magic numbers used:
              D0 CF 11 E0 A1 B1 1A E1  OLE2 compound document -- the container format an
                                       MSI database lives in. Also used by .doc and .msg,
                                       so the extension still matters for disambiguation.
              4D 5A ('MZ')             DOS/PE executable.
              50 4B 03 04 ('PK')       ZIP container -- MSIX/APPX are ZIP-based.

        .OUTPUTS
            PSPackageForge.ContainerDetection
    #>
    [CmdletBinding()]
    [OutputType('PSPackageForge.ContainerDetection')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

    $header = New-Object byte[] 8
    $stream = $null

    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $read   = $stream.Read($header, 0, 8)
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }

    $signature = if ($read -ge 8) { ($header | ForEach-Object { $_.ToString('X2') }) -join '' } else { '' }

    $byContent = if ($signature -like 'D0CF11E0A1B11AE1*') { [ContainerType]::Msi }
                 elseif ($signature -like '4D5A*')          { [ContainerType]::Exe }
                 elseif ($signature -like '504B0304*')      { [ContainerType]::Msix }
                 else                                       { [ContainerType]::Unknown }

    $byExtension = switch ($extension) {
        '.msi'  { [ContainerType]::Msi }
        '.exe'  { [ContainerType]::Exe }
        '.msix' { [ContainerType]::Msix }
        '.appx' { [ContainerType]::Msix }
        default { [ContainerType]::Unknown }
    }

    # Content wins. It is the thing that decides which provider can actually read the file.
    $effective = if ($byContent -ne [ContainerType]::Unknown) { $byContent } else { $byExtension }

    $mismatch = $byContent -ne [ContainerType]::Unknown -and
                $byExtension -ne [ContainerType]::Unknown -and
                $byContent -ne $byExtension

    [PSCustomObject] @{
        PSTypeName    = 'PSPackageForge.ContainerDetection'
        ContainerType = $effective
        ByContent     = $byContent
        ByExtension   = $byExtension
        Mismatch      = $mismatch
        HeaderHex     = $signature
    }
}

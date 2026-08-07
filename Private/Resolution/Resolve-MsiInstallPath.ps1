<#
    MSI directory resolution.

    Plan §8.1: locating an installed file offline requires a join, not a single table --

        File.Component_  ->  Component.Directory_  ->  Directory hierarchy (recursive walk)

    and even then public properties, Directory overrides and install conditions can change
    the real target. So "the File table contains a version" does NOT imply "the installation
    path is known with High confidence", and this module refuses to pretend otherwise.
#>

<#
    Well-known Windows Installer directory properties, and what they actually resolve to.

    The ProgramFilesFolder entry is the one people get wrong. On 64-bit Windows,
    ProgramFilesFolder is the *32-bit* location for every package, 32-bit or 64-bit --
    the 64-bit location is ProgramFiles64Folder. A tool that maps ProgramFilesFolder to
    C:\Program Files emits a detection rule that never matches for a 32-bit app, which is
    precisely the silent 0x87D00324 the plan is about.

    UserScope marks roots that live in a user profile. A component landing there is strong
    evidence -- not proof -- of a per-user install (plan §8.4).
#>
$script:MsiStandardDirectory = @{
    'TARGETDIR'             = @{ Environment = $null;                      UserScope = $false; Note = 'Installation root; the concrete location is decided at install time.' }
    'ProgramFilesFolder'    = @{ Environment = '%ProgramFiles(x86)%';      UserScope = $false; Note = 'On 64-bit Windows this is the 32-bit Program Files, for both 32-bit and 64-bit packages.' }
    'ProgramFiles64Folder'  = @{ Environment = '%ProgramFiles%';           UserScope = $false; Note = $null }
    'CommonFilesFolder'     = @{ Environment = '%CommonProgramFiles(x86)%'; UserScope = $false; Note = $null }
    'CommonFiles64Folder'   = @{ Environment = '%CommonProgramFiles%';     UserScope = $false; Note = $null }
    'WindowsFolder'         = @{ Environment = '%SystemRoot%';             UserScope = $false; Note = $null }
    'SystemFolder'          = @{ Environment = '%SystemRoot%\SysWOW64';    UserScope = $false; Note = 'SysWOW64 for a 32-bit package; System32 for a 64-bit package.' }
    'System64Folder'        = @{ Environment = '%SystemRoot%\System32';    UserScope = $false; Note = $null }
    'CommonAppDataFolder'   = @{ Environment = '%ProgramData%';            UserScope = $false; Note = $null }
    'AppDataFolder'         = @{ Environment = '%APPDATA%';                UserScope = $true;  Note = $null }
    'LocalAppDataFolder'    = @{ Environment = '%LOCALAPPDATA%';           UserScope = $true;  Note = $null }
    'PersonalFolder'        = @{ Environment = '%USERPROFILE%\Documents';  UserScope = $true;  Note = $null }
    'DesktopFolder'         = @{ Environment = '%USERPROFILE%\Desktop';    UserScope = $true;  Note = $null }
    'ProgramMenuFolder'     = @{ Environment = '%APPDATA%\Microsoft\Windows\Start Menu\Programs'; UserScope = $true; Note = $null }
    'StartMenuFolder'       = @{ Environment = '%APPDATA%\Microsoft\Windows\Start Menu';          UserScope = $true; Note = $null }
    'StartupFolder'         = @{ Environment = '%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup'; UserScope = $true; Note = $null }
    'TempFolder'            = @{ Environment = '%TEMP%';                   UserScope = $true;  Note = $null }
}


function ConvertFrom-MsiDefaultDir {
    <#
        .SYNOPSIS
            Extracts the long directory name from a Directory table DefaultDir value.

        .DESCRIPTION
            DefaultDir is not a plain name. Its full grammar is

                [target_short|]target_long[:[source_short|]source_long]

            so 'lkwuxpfh|FixtureNative' means the 8.3 name is lkwuxpfh and the real name is
            FixtureNative. The target side is what gets installed; the source side describes
            the layout inside the package and is irrelevant here.

            A value of '.' means "no new directory level" -- the component lands in the
            parent. Returning an empty string for it keeps the caller's join correct.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $DefaultDir
    )

    if ([string]::IsNullOrWhiteSpace($DefaultDir)) { return '' }

    # Drop the source side; only the install target matters.
    $target = ($DefaultDir -split ':', 2)[0]

    # Prefer the long name when a short|long pair is present.
    if ($target -match '\|') { $target = ($target -split '\|', 2)[1] }

    $target = $target.Trim()

    if ($target -eq '.') { return '' }

    return $target
}


function Resolve-MsiInstallPath {
    <#
        .SYNOPSIS
            Walks a Directory identifier up to a well-known root and reports the install
            path with an honest confidence.

        .DESCRIPTION
            Confidence follows plan §8.1:

              High   -- the chain terminates at a recognised standard directory and every
                        segment is a literal name.
              Medium -- the chain terminates at an unrecognised root, or a segment contains
                        a property token such as [INSTALLDIR], or the owning component is
                        conditional. A finding is raised in each case.
              Low    -- the chain could not be walked at all.

            The caller is expected to propagate the confidence into the EvidenceRecord
            rather than round it up.

        .OUTPUTS
            PSPackageForge.MsiPathResolution
    #>
    [CmdletBinding()]
    [OutputType('PSPackageForge.MsiPathResolution')]
    param(
        [Parameter(Mandatory)]
        [PSTypeName('PSPackageForge.MsiDatabase')]
        [object] $Database,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DirectoryId,

        # Condition on the owning Component, when there is one. A conditional component may
        # simply not be installed, which caps confidence at Medium.
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ComponentCondition
    )

    $findings   = [System.Collections.Generic.List[Finding]]::new()
    $segments   = [System.Collections.Generic.List[string]]::new()
    $confidence = [ConfidenceLevel]::High

    # Index once; a deep chain would otherwise be quadratic over the Directory table.
    $byId = @{}
    foreach ($directory in $Database.Directories) { $byId[$directory.Directory] = $directory }

    $currentId  = $DirectoryId
    $rootToken  = $null
    $visited    = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($currentId)) { break }

        # A malformed Directory table can contain a parent cycle. Refusing to loop forever
        # is worth the four lines.
        if (-not $visited.Add($currentId)) {
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'MSI_DIRECTORY_CYCLE' -Field 'InstallLocation' -Message (
                "The Directory table contains a parent cycle at '{0}'. The install path could not be resolved reliably." -f $currentId)))
            $confidence = [ConfidenceLevel]::Low
            break
        }

        if ($script:MsiStandardDirectory.ContainsKey($currentId)) {
            $rootToken = $currentId
            break
        }

        if (-not $byId.ContainsKey($currentId)) {
            # The chain references a directory that is not in the table.
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'MSI_DIRECTORY_UNRESOLVED' -Field 'InstallLocation' -Message (
                "Directory '{0}' is referenced but not defined in the Directory table, so the install path is a best effort." -f $currentId)))
            $rootToken  = $currentId
            $confidence = [ConfidenceLevel]::Medium
            break
        }

        $entry = $byId[$currentId]
        $name  = ConvertFrom-MsiDefaultDir -DefaultDir $entry.DefaultDir

        if ($name -match '\[[^\]]+\]') {
            # e.g. DefaultDir = '[INSTALLDIR]'. The real target is decided by a property at
            # install time, which is exactly the case plan §8.1 says must not claim High.
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'MSI_DIRECTORY_PROPERTY_TOKEN' -Field 'InstallLocation' -Message (
                "Directory '{0}' resolves through property token '{1}', so the installed path depends on a property set at install time. Verify the real location on a reference machine." -f $currentId, $name)))
            $confidence = [ConfidenceLevel]::Medium
        }

        if ($name) { $segments.Insert(0, $name) }

        $currentId = $entry.Parent
    }

    # A conditional component may not be installed at all.
    if (-not [string]::IsNullOrWhiteSpace($ComponentCondition)) {
        $findings.Add((New-ForgeFinding -Severity Warning -Code 'MSI_COMPONENT_CONDITIONAL' -Field 'InstallLocation' -Message (
            "The owning component is installed only when '{0}' is true, so this path may not exist on every client." -f $ComponentCondition)))
        if ($confidence -eq [ConfidenceLevel]::High) { $confidence = [ConfidenceLevel]::Medium }
    }

    $environmentRoot = $null
    $isUserScope     = $false

    if ($rootToken -and $script:MsiStandardDirectory.ContainsKey($rootToken)) {
        $standard        = $script:MsiStandardDirectory[$rootToken]
        $environmentRoot = $standard.Environment
        $isUserScope     = $standard.UserScope

        if ($null -eq $environmentRoot) {
            # TARGETDIR: a real root, but not one that maps to a concrete location offline.
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'MSI_DIRECTORY_ROOT_UNBOUND' -Field 'InstallLocation' -Message (
                "The directory chain terminates at TARGETDIR, whose concrete location is chosen at install time. Confirm the install location on a reference machine.")))
            if ($confidence -eq [ConfidenceLevel]::High) { $confidence = [ConfidenceLevel]::Medium }
        }
    }
    elseif ($rootToken) {
        if ($confidence -eq [ConfidenceLevel]::High) { $confidence = [ConfidenceLevel]::Medium }
    }

    $relative        = ($segments -join '\')
    $tokenPath       = if ($rootToken) { (@("[$rootToken]") + $segments) -join '\' } else { $relative }
    $environmentPath = if ($environmentRoot) {
        if ($relative) { '{0}\{1}' -f $environmentRoot, $relative } else { $environmentRoot }
    }
    else {
        $null
    }

    [PSCustomObject] @{
        PSTypeName       = 'PSPackageForge.MsiPathResolution'
        DirectoryId      = $DirectoryId
        RootToken        = $rootToken
        RelativePath     = $relative
        TokenPath        = $tokenPath
        EnvironmentPath  = $environmentPath
        IsUserScope      = $isUserScope
        Confidence       = $confidence
        Findings         = $findings.ToArray()
    }
}

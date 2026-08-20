#Requires -Version 5.1
<#
    .SYNOPSIS
        Builds Tests\Fixtures\wrapper-style.msi: a synthetic wrapper MSI shaped like
        Mozilla Firefox ESR's real package, used to test wrapper detection without
        committing (or downloading) a vendor installer.

    .DESCRIPTION
        DESIGN DECISION (supersedes an earlier plan to build this fixture with the WiX
        toolset, the way native-clean.msi was built). This fixture is built directly
        against the WindowsInstaller COM automation API instead -- the same API
        Private\Providers\Read-MsiDatabase.ps1 uses to READ an MSI. Two reasons:

          1. No toolchain install. A wrapper MSI needs no compiled payload, no cabinet,
             no MSI linker features -- just a handful of table rows and a summary
             stream. WiX buys nothing here that raw table INSERTs do not already give.
          2. Provenance. The committed generator script below *is* the fixture's
             provenance, the same way clean-native.wxs is native-clean.msi's provenance.
             A reviewer reads this file top to bottom and sees exactly which rows exist
             and why, instead of having to trust a compiled tool's output.

        The shape mirrors Firefox ESR (plan §8.1 / Private\Providers\Get-MsiEvidence.ps1):
        a ProductCode is present in the Property table, one Binary row holds the wrapped
        payload stub, one CustomAction of type 3074 (base type 2, "run an EXE from the
        Binary table", deferred + no-impersonate flags) launches it, and there is
        deliberately NO File table -- Get-MsiEvidence classifies MsiKind purely on
        Files.Count being zero, and Read-MsiDatabase treats a missing File table as
        normal, so the table is omitted rather than created empty.

        This script does not import PSPackageForge and must not: it has to be runnable
        standalone, on a machine that has never run Import-Module against this module, so
        the fixture's provenance does not itself depend on the thing it is testing.
        Invoke-WrapperFixtureMsiMember and Remove-WrapperFixtureComObject below are
        therefore small standalone re-implementations of
        Private\Providers\Invoke-MsiMember.ps1's InvokeMember plumbing and
        Private\Providers\Invoke-MsiMember.ps1's Remove-ComObject, not calls into the
        module.

        DETERMINISM NOTE. Every logical value written here (Property rows, the
        CustomAction, the Binary stream bytes, every SummaryInformation property this
        script sets) is a fixed literal, so rebuilding from this script reproduces the
        same table contents every time. The compiled .msi's raw BYTES are not guaranteed
        byte-identical across rebuilds regardless: the OLE2 compound-file storage layer
        that Windows Installer persists to stamps its own internal directory-entry
        timestamps and sector layout, which this automation API does not expose control
        over. That is an acceptable, documented gap (the fixture is committed once and
        is not intended to be diffed byte-for-byte on every regeneration) -- what matters
        is that the logical content, and therefore every test assertion against it,
        reproduces exactly.

    .PARAMETER OutputPath
        Where to write the generated MSI. Defaults to wrapper-style.msi next to this
        script, i.e. Tests\Fixtures\wrapper-style.msi.

    .EXAMPLE
        .\New-WrapperFixture.ps1

        Regenerates Tests\Fixtures\wrapper-style.msi in place.

    .NOTES
        Requires Windows Installer (msi.dll / the WindowsInstaller.Installer COM class),
        which means Windows. Idempotent: an existing file at -OutputPath is deleted
        first, so re-running this script always produces a fresh database rather than
        failing on "file already exists" or silently reusing stale table rows.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath 'wrapper-style.msi')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# msiOpenDatabaseModeCreate. Creates a brand-new database in transacted mode -- table and
# row changes are staged and only become durable once Database.Commit() is called below.
# (0 = ReadOnly, 1 = Transact an EXISTING db, 2 = Direct, 3 = Create, 4 = CreateDirect.)
$MsiOpenDatabaseModeCreate = 3


function Invoke-WrapperFixtureMsiMember {
    <#
        .SYNOPSIS
            Calls a method or reads/writes a property on a WindowsInstaller COM object.

        .DESCRIPTION
            Standalone twin of Private\Providers\Invoke-MsiMember.ps1's InvokeMember
            approach, duplicated rather than dot-sourced because this script must run
            without the module ever being imported (see the header design-decision note).
            WindowsInstaller.Installer is a late-bound IDispatch COM object; ordinary
            $object.Method() syntax against it is unreliable in Windows PowerShell 5.1,
            so every call goes through reflection instead.

        .PARAMETER Type
            InvokeMethod for methods (OpenDatabase, OpenView, Execute, Commit,
            CreateRecord, SetStream, Persist). GetProperty / SetProperty for properties
            (SummaryInformation, and reading/writing Record.StringData or
            SummaryInfo.Property).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Target,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('InvokeMethod', 'GetProperty', 'SetProperty')]
        [string] $Type,

        [Parameter()]
        [AllowNull()]
        [object[]] $Arguments
    )

    $binding = [System.Reflection.BindingFlags] $Type

    return $Target.GetType().InvokeMember($Name, $binding, $null, $Target, $Arguments)
}


function Remove-WrapperFixtureComObject {
    <#
        .SYNOPSIS
            Releases a runtime callable wrapper, tolerating anything that is not one.

        .DESCRIPTION
            Standalone twin of Private\Providers\Invoke-MsiMember.ps1's Remove-ComObject.
            Windows Installer keeps a handle on the .msi until every wrapper referencing
            it is released, so a leaked handle here would leave wrapper-style.msi locked
            after this script exits.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Releases an in-process COM wrapper. It touches no user-visible state, so -WhatIf would be meaningless.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) { return 0 }

    try {
        if ([System.Runtime.InteropServices.Marshal]::IsComObject($InputObject)) {
            return [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($InputObject)
        }
    }
    catch {
        Write-Verbose "Could not release COM object: $($_.Exception.Message)"
    }

    return 0
}


function Invoke-WrapperFixtureSql {
    <#
        .SYNOPSIS
            Runs a non-parameterised MSI SQL statement (CREATE TABLE, or an INSERT with
            no stream column) to completion, then releases the view.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [object] $Database,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Query
    )

    $view = $null
    try {
        $view = Invoke-WrapperFixtureMsiMember -Target $Database -Name 'OpenView' -Type InvokeMethod -Arguments @($Query)
        $null = Invoke-WrapperFixtureMsiMember -Target $view -Name 'Execute' -Type InvokeMethod -Arguments $null
    }
    finally {
        if ($view) {
            try { $null = Invoke-WrapperFixtureMsiMember -Target $view -Name 'Close' -Type InvokeMethod -Arguments $null } catch {
                Write-Verbose "Closing MSI view failed (already closed?): $($_.Exception.Message)"
            }
            $null = Remove-WrapperFixtureComObject -InputObject $view
        }
    }
}


<#
    Fixed identity constants -- arbitrary but pinned, so the fixture's identity is
    reproducible across regenerations. Kept deliberately unrelated to Mozilla Firefox's
    real ProductName/UpgradeCode/ProductCode, and to each other, so this fixture cannot
    accidentally collide with a Config\known-quirks.psd1 entry keyed on real-world
    identity: it must classify as Wrapper on its own MSI-table shape alone, matching no
    quirk.
#>
$ProductCode = '{DEADBEEF-0000-4000-8000-000000000001}'
$UpgradeCode = '{DEADBEEF-0000-4000-8000-000000000002}'
$PackageCode = '{DEADBEEF-0000-4000-8000-000000000003}'

$ProductName    = 'PSPackageForge Wrapper Fixture'
$ProductVersion = '1.0.0.0'
$Manufacturer   = 'PSPackageForge Project'

$installer   = $null
$database    = $null
$summaryInfo = $null
$streamFile  = $null

try {
    if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Generate synthetic wrapper-style MSI test fixture')) { return }

    if (Test-Path -LiteralPath $OutputPath) {
        # Idempotent: a stale fixture from a previous run must not linger with old rows.
        Remove-Item -LiteralPath $OutputPath -Force
    }

    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database  = Invoke-WrapperFixtureMsiMember -Target $installer -Name 'OpenDatabase' -Type InvokeMethod -Arguments @($OutputPath, $MsiOpenDatabaseModeCreate)

    # ---- Schema -------------------------------------------------------------------
    # Deliberately no File or Component table: Get-MsiEvidence classifies MsiKind from
    # Files.Count alone, and Read-MsiDatabase treats a missing table as an empty
    # collection rather than an error, so "missing" is the correct way to express "zero
    # rows" here, not an empty table.
    Invoke-WrapperFixtureSql -Database $database -Query (
        'CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(0) NOT NULL LOCALIZABLE PRIMARY KEY `Property`)')

    Invoke-WrapperFixtureSql -Database $database -Query (
        'CREATE TABLE `Binary` (`Name` CHAR(72) NOT NULL, `Data` OBJECT NOT NULL PRIMARY KEY `Name`)')

    Invoke-WrapperFixtureSql -Database $database -Query (
        'CREATE TABLE `CustomAction` (`Action` CHAR(72) NOT NULL, `Type` LONG NOT NULL, `Source` CHAR(72), `Target` CHAR(255) PRIMARY KEY `Action`)')

    Invoke-WrapperFixtureSql -Database $database -Query (
        'CREATE TABLE `InstallExecuteSequence` (`Action` CHAR(72) NOT NULL, `Condition` CHAR(255), `Sequence` LONG PRIMARY KEY `Action`)')

    Invoke-WrapperFixtureSql -Database $database -Query (
        'CREATE TABLE `Directory` (`Directory` CHAR(72) NOT NULL, `Directory_Parent` CHAR(72), `DefaultDir` CHAR(255) NOT NULL LOCALIZABLE PRIMARY KEY `Directory`)')

    # ---- Property rows --------------------------------------------------------------
    $properties = [ordered] @{
        ProductCode    = $ProductCode
        ProductName    = $ProductName
        ProductVersion = $ProductVersion
        Manufacturer   = $Manufacturer
        ProductLanguage = '1033'
        ALLUSERS       = '1'
        UpgradeCode    = $UpgradeCode
    }

    foreach ($name in $properties.Keys) {
        Invoke-WrapperFixtureSql -Database $database -Query (
            "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('{0}', '{1}')" -f $name, $properties[$name])
    }

    # ---- Directory row ----------------------------------------------------------------
    # A single TARGETDIR row -- the root every MSI's Directory table resolves against --
    # with no children. This is not what makes the fixture a wrapper (that is the empty
    # File table); it is here only because a wrapper MSI shaped like Firefox ESR still
    # carries a minimal Directory table in practice.
    Invoke-WrapperFixtureSql -Database $database -Query (
        "INSERT INTO ``Directory`` (``Directory``, ``DefaultDir``) VALUES ('TARGETDIR', 'SourceDir')")

    # ---- CustomAction + InstallExecuteSequence -----------------------------------------
    # Type 3074 = base type 2 ("run an EXE stored in the Binary table") plus msidbCustomActionTypeInScript (0x0400,
    # deferred execution) and msidbCustomActionTypeNoImpersonate (0x0800, run as the
    # installing account) -- exactly Firefox ESR's real value (Get-MsiEvidence.ps1's
    # header comment). Get-MsiCustomActionBaseType masks this down to 2.
    Invoke-WrapperFixtureSql -Database $database -Query (
        "INSERT INTO ``CustomAction`` (``Action``, ``Type``, ``Source``, ``Target``) VALUES ('RunWrappedSetup', 3074, 'WrappedSetup', '/S')")

    Invoke-WrapperFixtureSql -Database $database -Query (
        "INSERT INTO ``InstallExecuteSequence`` (``Action``, ``Condition``, ``Sequence``) VALUES ('RunWrappedSetup', 'NOT Installed', 6400)")

    # ---- Binary row (stream column, needs a bound Record rather than literal SQL) ------
    # 64 bytes of 'MZ' followed by zeros: enough to look like the start of a PE stub
    # without needing a real executable. The Binary table's presence is not the wrapper
    # signal (Get-MsiEvidence.Tests.ps1's 7-Zip case has four Binary rows and is
    # emphatically native) -- the CustomAction that launches this row, combined with the
    # absent File table, is what matters. The bytes themselves are never inspected by
    # the module; only Binary.Name is ever selected (Read-MsiDatabase.ps1).
    $streamBytes = New-Object byte[] 64
    $streamBytes[0] = 0x4D   # 'M'
    $streamBytes[1] = 0x5A   # 'Z'
    $streamFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
    [System.IO.File]::WriteAllBytes($streamFile, $streamBytes)

    $binaryView   = $null
    $binaryRecord = $null
    try {
        $binaryView   = Invoke-WrapperFixtureMsiMember -Target $database -Name 'OpenView' -Type InvokeMethod -Arguments @('INSERT INTO `Binary` (`Name`, `Data`) VALUES (?, ?)')
        $binaryRecord = Invoke-WrapperFixtureMsiMember -Target $installer -Name 'CreateRecord' -Type InvokeMethod -Arguments @(2)

        $null = Invoke-WrapperFixtureMsiMember -Target $binaryRecord -Name 'StringData' -Type SetProperty -Arguments @(1, 'WrappedSetup')
        $null = Invoke-WrapperFixtureMsiMember -Target $binaryRecord -Name 'SetStream'  -Type InvokeMethod -Arguments @(2, $streamFile)
        $null = Invoke-WrapperFixtureMsiMember -Target $binaryView   -Name 'Execute'    -Type InvokeMethod -Arguments @($binaryRecord)
    }
    finally {
        if ($binaryView) {
            try { $null = Invoke-WrapperFixtureMsiMember -Target $binaryView -Name 'Close' -Type InvokeMethod -Arguments $null } catch {
                Write-Verbose "Closing MSI view failed (already closed?): $($_.Exception.Message)"
            }
            $null = Remove-WrapperFixtureComObject -InputObject $binaryView
        }
        if ($binaryRecord) { $null = Remove-WrapperFixtureComObject -InputObject $binaryRecord }
    }

    # ---- SummaryInformation ---------------------------------------------------------
    # 20 reserves update slots for every property this script sets, plus headroom; the
    # Windows Installer SDK examples for authoring SummaryInformation from scratch use
    # the same margin-above-actual-count convention.
    $summaryInfo = Invoke-WrapperFixtureMsiMember -Target $database -Name 'SummaryInformation' -Type GetProperty -Arguments @(20)

    $summaryProperties = @(
        @{ Id = 1;  Value = 1252 }                                            # PID_CODEPAGE (ANSI Latin 1).
        @{ Id = 2;  Value = 'PSPackageForge Wrapper Fixture Installer Database' } # PID_TITLE.
        @{ Id = 3;  Value = 'Wrapper-style MSI test fixture' }                # PID_SUBJECT.
        @{ Id = 4;  Value = $Manufacturer }                                   # PID_AUTHOR.
        @{ Id = 7;  Value = 'Intel;1033' }                                    # PID_TEMPLATE (x86, en-US).
        @{ Id = 9;  Value = $PackageCode }                                    # PID_REVNUMBER (package code).
        @{ Id = 14; Value = 200 }                                             # PID_PAGECOUNT (min. Installer version 2.00).
        @{ Id = 15; Value = 0 }                                               # PID_WORDCOUNT (no special source flags).
        @{ Id = 18; Value = 'New-WrapperFixture.ps1 (PSPackageForge test fixtures)' } # PID_APPNAME.
    )

    foreach ($entry in $summaryProperties) {
        $null = Invoke-WrapperFixtureMsiMember -Target $summaryInfo -Name 'Property' -Type SetProperty -Arguments @($entry.Id, $entry.Value)
    }

    $null = Invoke-WrapperFixtureMsiMember -Target $summaryInfo -Name 'Persist' -Type InvokeMethod -Arguments $null

    # ---- Commit -----------------------------------------------------------------------
    $null = Invoke-WrapperFixtureMsiMember -Target $database -Name 'Commit' -Type InvokeMethod -Arguments $null

    Write-Host "Wrote $OutputPath" -ForegroundColor Green
}
finally {
    if ($streamFile -and (Test-Path -LiteralPath $streamFile)) {
        Remove-Item -LiteralPath $streamFile -Force -ErrorAction SilentlyContinue
    }

    if ($summaryInfo) { $null = Remove-WrapperFixtureComObject -InputObject $summaryInfo }
    if ($database)    { $null = Remove-WrapperFixtureComObject -InputObject $database }
    if ($installer)   { $null = Remove-WrapperFixtureComObject -InputObject $installer }

    # Windows Installer holds the file open until the RCWs are actually collected.
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

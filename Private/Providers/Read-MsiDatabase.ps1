function Read-MsiDatabase {
    <#
        .SYNOPSIS
            Opens an MSI read-only and returns the tables PSPackageForge reasons about.

        .DESCRIPTION
            The only place in the module that talks to WindowsInstaller COM. Everything
            downstream works on plain PowerShell objects, which is what makes the MSI
            provider unit-testable without an MSI.

            Two things this function is careful about:

            1. **It opens the database read-only (mode 0).** Nothing in PSPackageForge ever
               writes to an installer it was handed.

            2. **It releases every COM object it creates.** An unreleased view or database
               keeps a file handle on the MSI, so a caller that scaffolds a package and then
               tries to copy the installer gets a sharing violation from a lock this module
               left behind. The finally block and the explicit release are load-bearing.

            Missing tables are normal, not exceptional. A wrapper MSI legitimately has no
            File table; an installer with no upgrade relationships has no Upgrade table.
            Callers get an empty collection and the TablesPresent list, and decide for
            themselves what the absence means.

        .OUTPUTS
            PSPackageForge.MsiDatabase
    #>
    [CmdletBinding()]
    [OutputType('PSPackageForge.MsiDatabase')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath

    $installer = $null
    $database  = $null

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer

        # Mode 0 = msiOpenDatabaseModeReadOnly.
        $database = Invoke-MsiMember -Target $installer -Name 'OpenDatabase' -Type InvokeMethod -Arguments @($resolved, 0)

        $tablesPresent = @(
            Get-MsiRecordSet -Database $database -Query 'SELECT `Name` FROM `_Tables`' -ColumnCount 1 |
                ForEach-Object { $_[0] }
        )

        # ---- Property -----------------------------------------------------------------
        $properties = @{}
        if ($tablesPresent -contains 'Property') {
            foreach ($row in Get-MsiRecordSet -Database $database -Query 'SELECT `Property`,`Value` FROM `Property`' -ColumnCount 2) {
                $properties[$row[0]] = $row[1]
            }
        }

        # ---- SummaryInformation -------------------------------------------------------
        # Property 7 (Template) carries the platform and language, and is the only
        # trustworthy architecture signal in an MSI. Never infer architecture from the host.
        $summary = @{}
        try {
            $summaryInfo = Invoke-MsiMember -Target $database -Name 'SummaryInformation' -Type GetProperty -Arguments @(0)

            foreach ($entry in @(
                @{ Id = 3;  Name = 'Subject' }
                @{ Id = 4;  Name = 'Author' }
                @{ Id = 7;  Name = 'Template' }
                @{ Id = 9;  Name = 'RevisionNumber' }
                @{ Id = 14; Name = 'PageCount' }
                @{ Id = 15; Name = 'WordCount' }
                @{ Id = 18; Name = 'CreatingApplication' }
            )) {
                try {
                    $value = Invoke-MsiMember -Target $summaryInfo -Name 'Property' -Type GetProperty -Arguments @($entry.Id)
                    if ($null -ne $value -and "$value".Length -gt 0) { $summary[$entry.Name] = $value }
                }
                catch {
                    # An absent summary property is normal, not an error. Most MSIs populate
                    # only a handful of the stream's slots.
                    Write-Verbose "Summary property $($entry.Id) ($($entry.Name)) not present."
                }
            }

            $null = Remove-ComObject -InputObject $summaryInfo
        }
        catch {
            Write-Verbose "SummaryInformation unavailable for '$resolved': $($_.Exception.Message)"
        }

        # ---- Payload and layout tables --------------------------------------------------
        $files = @()
        if ($tablesPresent -contains 'File') {
            $files = @(
                Get-MsiRecordSet -Database $database -Query 'SELECT `File`,`Component_`,`FileName`,`FileSize`,`Version`,`Language`,`Attributes`,`Sequence` FROM `File`' -ColumnCount 8 |
                    ForEach-Object {
                        [PSCustomObject] @{
                            File       = $_[0]
                            Component  = $_[1]
                            FileName   = $_[2]
                            FileSize   = $_[3]
                            Version    = $_[4]
                            Language   = $_[5]
                            Attributes = $_[6]
                            Sequence   = $_[7]
                        }
                    }
            )
        }

        $components = @()
        if ($tablesPresent -contains 'Component') {
            $components = @(
                Get-MsiRecordSet -Database $database -Query 'SELECT `Component`,`ComponentId`,`Directory_`,`Attributes`,`Condition`,`KeyPath` FROM `Component`' -ColumnCount 6 |
                    ForEach-Object {
                        [PSCustomObject] @{
                            Component   = $_[0]
                            ComponentId = $_[1]
                            Directory   = $_[2]
                            Attributes  = $_[3]
                            Condition   = $_[4]
                            KeyPath     = $_[5]
                        }
                    }
            )
        }

        $directories = @()
        if ($tablesPresent -contains 'Directory') {
            $directories = @(
                Get-MsiRecordSet -Database $database -Query 'SELECT `Directory`,`Directory_Parent`,`DefaultDir` FROM `Directory`' -ColumnCount 3 |
                    ForEach-Object {
                        [PSCustomObject] @{
                            Directory = $_[0]
                            Parent    = $_[1]
                            DefaultDir = $_[2]
                        }
                    }
            )
        }

        $features = @()
        if ($tablesPresent -contains 'Feature') {
            $features = @(
                Get-MsiRecordSet -Database $database -Query 'SELECT `Feature`,`Feature_Parent`,`Title`,`Level`,`Directory_`,`Attributes` FROM `Feature`' -ColumnCount 6 |
                    ForEach-Object {
                        [PSCustomObject] @{
                            Feature    = $_[0]
                            Parent     = $_[1]
                            Title      = $_[2]
                            Level      = $_[3]
                            Directory  = $_[4]
                            Attributes = $_[5]
                        }
                    }
            )
        }

        $upgrades = @()
        if ($tablesPresent -contains 'Upgrade') {
            $upgrades = @(
                Get-MsiRecordSet -Database $database -Query 'SELECT `UpgradeCode`,`VersionMin`,`VersionMax`,`Attributes`,`ActionProperty` FROM `Upgrade`' -ColumnCount 5 |
                    ForEach-Object {
                        [PSCustomObject] @{
                            UpgradeCode    = $_[0]
                            VersionMin     = $_[1]
                            VersionMax     = $_[2]
                            Attributes     = $_[3]
                            ActionProperty = $_[4]
                        }
                    }
            )
        }

        # ---- Wrapper signals ------------------------------------------------------------
        # Only Name is selected from Binary. The Data column is a stream and reading it as
        # StringData throws -- and the payload is irrelevant anyway; its presence is the
        # signal (plan §8.1).
        $binaries = @()
        if ($tablesPresent -contains 'Binary') {
            $binaries = @(
                Get-MsiRecordSet -Database $database -Query 'SELECT `Name` FROM `Binary`' -ColumnCount 1 |
                    ForEach-Object { $_[0] }
            )
        }

        $customActions = @()
        if ($tablesPresent -contains 'CustomAction') {
            $customActions = @(
                Get-MsiRecordSet -Database $database -Query 'SELECT `Action`,`Type`,`Source`,`Target` FROM `CustomAction`' -ColumnCount 4 |
                    ForEach-Object {
                        [PSCustomObject] @{
                            Action = $_[0]
                            Type   = $_[1]
                            Source = $_[2]
                            Target = $_[3]
                        }
                    }
            )
        }

        [PSCustomObject] @{
            PSTypeName         = 'PSPackageForge.MsiDatabase'
            Path               = $resolved
            TablesPresent      = $tablesPresent
            Properties         = $properties
            SummaryInformation = $summary
            Files              = $files
            Components         = $components
            Directories        = $directories
            Features           = $features
            Upgrades           = $upgrades
            Binaries           = $binaries
            CustomActions      = $customActions
        }
    }
    finally {
        if ($database)  { $null = Remove-ComObject -InputObject $database }
        if ($installer) { $null = Remove-ComObject -InputObject $installer }

        # Windows Installer holds the file open until the RCWs are actually collected.
        # Without this the MSI stays locked for the rest of the process.
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

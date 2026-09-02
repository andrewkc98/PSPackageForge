function Add-ForgeInstalledAppUninstallEvidence {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Adds in-memory evidence and findings only; it changes no external state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Entry,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[Finding]] $Findings,
        [Parameter(Mandatory)] [scriptblock] $AddEvidence
    )

    $productCodePattern = '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$'
    $claimsMsiRegistration = [int] $Entry.WindowsInstaller -eq 1
    $isMsiRegistration = $claimsMsiRegistration -and ([string] $Entry.SubKey -match $productCodePattern)

    if ($claimsMsiRegistration -and -not $isMsiRegistration) {
        $Findings.Add((New-ForgeFinding -Severity Warning -Code 'INSTALLED_APP_MSI_REGISTRATION_INVALID' -Field 'ProductCode' -Message (
            'WindowsInstaller is set, but the uninstall subkey is not a product-code GUID. No MSI product code or msiexec command was inferred.')))
    }

    if ($isMsiRegistration) {
        $productCode = ([string] $Entry.SubKey).ToUpperInvariant()
        & $AddEvidence 'ProductCode' $productCode ([ConfidenceLevel]::High) 'Confirmed Windows Installer registration whose uninstall subkey is a product-code GUID.'
        & $AddEvidence 'ProductCodePresent' $true ([ConfidenceLevel]::High) 'Confirmed Windows Installer product-code registration.'
        & $AddEvidence 'SupportsMsiUninstall' $true ([ConfidenceLevel]::High) 'Installed-product registration confirms msiexec product-code removal support.'

        $msiUninstall = [CommandSpec]::new('msiexec.exe', @('/x', $productCode, '/qn'), @(0, 3010, 1641, 1707))
        & $AddEvidence 'UninstallCommand' $msiUninstall.ToOrderedDictionary() ([ConfidenceLevel]::High) (
            'Deterministic quiet removal command from a confirmed Windows Installer product-code registration.')
        return
    }

    $quietCommand = [string] $Entry.QuietUninstallString
    $normalCommand = [string] $Entry.UninstallString
    $selectedCommand = if (-not [string]::IsNullOrWhiteSpace($quietCommand)) { $quietCommand } else { $normalCommand }
    $commandConfidence = if (-not [string]::IsNullOrWhiteSpace($quietCommand)) {
        [ConfidenceLevel]::High
    }
    else {
        [ConfidenceLevel]::Medium
    }

    if ([string]::IsNullOrWhiteSpace($selectedCommand)) {
        $Findings.Add((New-ForgeFinding -Severity Warning -Code 'INSTALLED_APP_UNINSTALL_COMMAND_UNRESOLVED' -Field 'UninstallCommand' -Message (
            'No portable QuietUninstallString or UninstallString is registered. No uninstall command was guessed.')))
        return
    }

    $conversion = ConvertTo-ForgeDiscoveredCommand -CommandLine $selectedCommand
    if (-not $conversion.Success) {
        $Findings.Add((New-ForgeFinding -Severity Warning -Code 'INSTALLED_APP_UNINSTALL_COMMAND_UNRESOLVED' -Field 'UninstallCommand' -Message (
            'The registered uninstall command could not be preserved safely as a structured command: {0}' -f $conversion.Reason)))
        return
    }

    $notes = if ($commandConfidence -eq [ConfidenceLevel]::High) {
        'QuietUninstallString parsed into a structured command and verified by argument round-trip.'
    }
    else {
        'UninstallString parsed into a structured command and verified by argument round-trip; silent behavior is not registered.'
    }
    & $AddEvidence 'UninstallCommand' $conversion.Command $commandConfidence $notes

    if ($commandConfidence -eq [ConfidenceLevel]::Medium) {
        $Findings.Add((New-ForgeFinding -Severity Warning -Code 'INSTALLED_APP_UNINSTALL_SILENCE_UNVERIFIED' -Field 'UninstallCommand' -Message (
            'Only UninstallString is registered. PSPackageForge did not append guessed silent switches; verify unattended behavior before deployment.')))
    }
    $Findings.Add((New-ForgeFinding -Severity Warning -Code 'INSTALLED_APP_EXIT_CODES_UNVERIFIED' -Field 'UninstallCommand' -Message (
        'The vendor uninstaller does not publish a return-code contract in the registry. Only exit code 0 is modeled as success.')))
}


function Add-ForgeInstalledAppDetectionEvidence {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Adds in-memory evidence and findings only; it changes no external state.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Entry,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[Finding]] $Findings,
        [Parameter(Mandatory)] [scriptblock] $AddEvidence
    )

    if (-not [string]::IsNullOrWhiteSpace([string] $Entry.DisplayIcon) -and
            -not [string]::IsNullOrWhiteSpace([string] $Entry.InstallLocation)) {
        $iconPath = Get-ForgeDisplayIconPath -DisplayIcon ([string] $Entry.DisplayIcon)
        if (-not [string]::IsNullOrWhiteSpace($iconPath) -and
                (Test-ForgeDetectionTarget -Path $iconPath -InstallLocation ([string] $Entry.InstallLocation))) {
            & $AddEvidence 'DetectionTarget' $iconPath ([ConfidenceLevel]::Medium) (
                'DisplayIcon names an existing executable inside the observed InstallLocation; it is inferred as an existence-only detection target.')
            $Findings.Add((New-ForgeFinding -Severity Info -Code 'INSTALLED_APP_DETECTION_TARGET_INFERRED' -Field 'DetectionTarget' -Message (
                'DisplayIcon was accepted as a Medium-confidence detection target after path and file validation. Verify it represents the installed application.')))
            return
        }
    }

    $Findings.Add((New-ForgeFinding -Severity Warning -Code 'INSTALLED_APP_DETECTION_TARGET_UNRESOLVED' -Field 'DetectionTarget' -Message (
        'DisplayIcon did not identify a safe existing application executable inside InstallLocation. No detection target was guessed.')))
}

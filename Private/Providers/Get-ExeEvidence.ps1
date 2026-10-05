function Get-ExeEvidence {
    [CmdletBinding()]
    [OutputType('PSPackageForge.ProviderResult')]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Path)
    $evidence = [System.Collections.Generic.List[EvidenceRecord]]::new()
    $findings = [System.Collections.Generic.List[Finding]]::new()
    $markers = @('NullsoftInst','Inno Setup Setup Data','InstallShield Setup Launcher','SquirrelSetup','SquirrelAwareVersion','Installer for Squirrel-based applications')
    $metadata = Read-PortableExecutableData -Path $Path -AsciiMarkers $markers -Utf16LEMarkers $markers
    $add = { param([string]$field,[object]$value,[ConfidenceLevel]$confidence,[string]$notes,[EvidenceSource]$evidenceSource = [EvidenceSource]::PeMetadata) if ($null -ne $value -and -not ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) { $evidence.Add([EvidenceRecord]::new($field,$value,$evidenceSource,$confidence,$notes)) } }
    & $add 'ContainerType' 'Exe' ([ConfidenceLevel]::High) 'The supplied file is a portable executable.'
    & $add 'PayloadType' 'Exe' ([ConfidenceLevel]::High) 'The supplied executable is the installer payload container.'
    & $add 'MsiKind' 'NotApplicable' ([ConfidenceLevel]::High) 'MSI classification does not apply to an EXE.'
    if ($metadata.Architecture -ne 'Unknown') { & $add 'InstallerArchitecture' $metadata.Architecture ([ConfidenceLevel]::High) 'Read from the PE COFF machine field.' }
    $version = $metadata.FileVersionInfo
    & $add 'ProductName' $version.ProductName ([ConfidenceLevel]::Medium) 'Read from the executable version resource.'
    & $add 'Manufacturer' $version.CompanyName ([ConfidenceLevel]::Medium) 'Read from the executable version resource.'
    $productVersion = if (-not [string]::IsNullOrWhiteSpace($version.ProductVersion)) { $version.ProductVersion } else { $version.FileVersion }
    & $add 'ProductVersionRaw' $productVersion ([ConfidenceLevel]::Medium) 'Read from the executable version resource.'
    $frameworkMatches = [System.Collections.Generic.List[InstallerFramework]]::new()
    $observedMarkers = @($metadata.AsciiMarkersFound) + @($metadata.Utf16LEMarkersFound)
    if ($observedMarkers -contains 'NullsoftInst') { $frameworkMatches.Add([InstallerFramework]::Nsis) }
    if ($observedMarkers -contains 'Inno Setup Setup Data') { $frameworkMatches.Add([InstallerFramework]::InnoSetup) }
    if ($observedMarkers -contains 'InstallShield Setup Launcher') { $frameworkMatches.Add([InstallerFramework]::InstallShield) }
    if (@($observedMarkers | Where-Object { $_ -in @('SquirrelSetup','SquirrelAwareVersion','Installer for Squirrel-based applications') }).Count -gt 0) { $frameworkMatches.Add([InstallerFramework]::Squirrel) }
    if ($metadata.SectionNames -contains '.wixburn') { $frameworkMatches.Add([InstallerFramework]::WiXBurn) }
    $fixedOrder = @([InstallerFramework]::Nsis,[InstallerFramework]::InnoSetup,[InstallerFramework]::InstallShield,[InstallerFramework]::Squirrel,[InstallerFramework]::WiXBurn)
    $candidates = @($fixedOrder | Where-Object { $frameworkMatches -contains $_ })
    & $add 'FrameworkCandidates' $candidates ([ConfidenceLevel]::High) 'Observed framework candidates, reported in fixed order.'
    $fileName = Split-Path -Leaf $Path
    if ($candidates.Count -gt 1) { $findings.Add((New-ForgeFinding -Severity Warning -Code 'FRAMEWORK_AMBIGUOUS' -Field 'Framework' -Message ("Multiple EXE framework signatures matched: {0}." -f ($candidates -join ', ')))) }
    elseif ($candidates.Count -eq 0) { $findings.Add((New-ForgeFinding -Severity Warning -Code 'FRAMEWORK_UNRESOLVED' -Field 'Framework' -Message 'No recognized EXE framework signature was observed.')) }
    elseif ($candidates.Count -eq 1) {
        $framework = $candidates[0]
        & $add 'Framework' $framework ([ConfidenceLevel]::High) 'Recognized from a conservative PE signature.'
        if ($framework -eq [InstallerFramework]::InstallShield) { $findings.Add((New-ForgeFinding -Severity Warning -Code 'EXE_ARGUMENT_PROFILE_UNRESOLVED' -Field 'InstallCommand' -Message 'InstallShield was recognized, but this provider has no safe silent argument profile.')) }
        else {
            $arguments = switch ($framework) { ([InstallerFramework]::Nsis) { @('/S') } ([InstallerFramework]::InnoSetup) { @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-') } ([InstallerFramework]::Squirrel) { @('--silent') } ([InstallerFramework]::WiXBurn) { @('/quiet','/norestart') } }
            & $add 'InstallCommand' ([CommandSpec]::new($fileName,$arguments,@(0))) ([ConfidenceLevel]::Medium) 'Conservative framework profile; verify arguments and exit behavior before deployment.' ([EvidenceSource]::Inferred)
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'EXE_EXIT_CODES_UNVERIFIED' -Field 'InstallCommand' -Message 'Only exit code 0 is recorded; the installer exit-code contract is unverified.'))
            if ($framework -eq [InstallerFramework]::Squirrel) { $findings.Add((New-ForgeFinding -Severity Warning -Code 'SQUIRREL_COMPLETION_UNVERIFIED' -Field 'InstallCommand' -Message 'Squirrel completion and child-process behavior are unverified.')) }
        }
    }
    [PSCustomObject]@{ PSTypeName='PSPackageForge.ProviderResult'; Provider='Exe'; Evidence=$evidence.ToArray(); Findings=$findings.ToArray(); Raw=$metadata }
}

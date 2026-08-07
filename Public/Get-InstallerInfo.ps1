function Get-InstallerInfo {
    <#
        .SYNOPSIS
            Identifies an installer and gathers evidence about it.

        .DESCRIPTION
            Answers "what is this file?" and nothing else. Deployment decisions -- install
            command, uninstall command, context, detection -- belong to the PackageSpec
            resolver. Keeping the two apart is what stops a discovered value silently
            becoming a deployment choice (plan §2).

            Providers emit EvidenceRecord objects; Merge-InstallerEvidence resolves them by
            documented precedence and raises EVIDENCE_CONFLICT where high-confidence sources
            disagree. Every field on the returned object can be traced back through
            GetEvidence() to the source and confidence that produced it.

        .PARAMETER Path
            Path to the installer.

        .PARAMETER AdditionalEvidence
            Evidence from other providers -- known quirks, reference-machine discovery, or a
            user override -- merged in with the normal precedence rules. This is how a value
            the installer cannot reveal enters the picture while keeping honest provenance.

        .EXAMPLE
            Get-InstallerInfo -Path .\7z2602-x64.msi

        .EXAMPLE
            (Get-InstallerInfo -Path .\7z2602-x64.msi).GetEvidence('InstallLocation')

            Shows where the resolved install location actually came from.

        .OUTPUTS
            InstallerInfo

        .NOTES
            The signature deliberately uses loose types.

            In Windows PowerShell 5.1 a class defined in a .psm1 is not visible to the
            caller's scope unless they import the module with `using module`. Parameter
            types and [OutputType()] on an EXPORTED function are resolved in the CALLER's
            type context, so declaring [EvidenceRecord[]] here makes the cmdlet unusable
            after a plain Import-Module -- it fails at invocation with "Unable to find type".

            Public functions therefore take [object[]] and validate at runtime; the string
            form of [OutputType] documents the return type without asking the caller to
            resolve it. Private functions are called only from module scope and use the
            real class types freely.
    #>
    [CmdletBinding()]
    [OutputType('InstallerInfo')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'PSPath')]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [AllowEmptyCollection()]
        [object[]] $AdditionalEvidence = @()
    )

    process {
        $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath

        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            throw [System.IO.FileNotFoundException]::new("Installer not found or is not a file: $resolvedPath")
        }

        $item = Get-Item -LiteralPath $resolvedPath

        $info          = [InstallerInfo]::new()
        $info.Path     = $resolvedPath
        $info.FileName = $item.Name
        $info.FileSize = $item.Length
        $info.SHA256   = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash

        $info.Signature = Get-InstallerSignature -Path $resolvedPath

        $evidence = [System.Collections.Generic.List[EvidenceRecord]]::new()
        $findings = [System.Collections.Generic.List[Finding]]::new()

        # ---- What kind of file is this? ------------------------------------------------
        $detection = Get-InstallerContainerType -Path $resolvedPath

        if ($detection.Mismatch) {
            $findings.Add((New-ForgeFinding -Severity Warning -Code 'CONTAINER_EXTENSION_MISMATCH' -Field 'ContainerType' -Message (
                "The file extension says {0} but the content is {1}. Treating it as {1}. Confirm this is the file you intended to package." -f
                    $detection.ByExtension, $detection.ByContent)))
        }

        if ($detection.ContainerType -eq [ContainerType]::Unknown) {
            $findings.Add((New-ForgeFinding -Severity Blocking -Code 'CONTAINER_UNKNOWN' -Field 'ContainerType' -Message (
                "The file is neither a Windows Installer database, a PE executable, nor an MSIX/APPX package (header {0}). PSPackageForge cannot identify it." -f
                    $detection.HeaderHex)))
        }

        # ---- Provider dispatch ----------------------------------------------------------
        switch ($detection.ContainerType) {

            ([ContainerType]::Msi) {
                try {
                    $result = Get-MsiEvidence -Path $resolvedPath
                    foreach ($record in $result.Evidence) { $evidence.Add($record) }
                    foreach ($finding in $result.Findings) { $findings.Add($finding) }
                }
                catch {
                    $findings.Add((New-ForgeFinding -Severity Blocking -Code 'MSI_READ_FAILED' -Field 'ContainerType' -Message (
                        "The file has an MSI container signature but the Windows Installer database could not be read: {0}" -f $_.Exception.Message)))
                }
                break
            }

            ([ContainerType]::Exe) {
                $evidence.Add([EvidenceRecord]::new('ContainerType', 'Exe', [EvidenceSource]::Inferred, [ConfidenceLevel]::High,
                    'PE executable header.'))

                # EXE framework evidence is build order step 11. Until then, say so rather
                # than emitting a half-answer that looks complete.
                $findings.Add((New-ForgeFinding -Severity Blocking -Code 'EXE_ANALYSIS_NOT_IMPLEMENTED' -Field 'Framework' -Message (
                    'EXE installer framework analysis is not implemented yet (build order step 11). Identity, hash and signature are reported; installer framework and commands are not.')))
                break
            }

            ([ContainerType]::Msix) {
                $evidence.Add([EvidenceRecord]::new('ContainerType', 'Msix', [EvidenceSource]::Inferred, [ConfidenceLevel]::High,
                    'ZIP container with an MSIX/APPX extension.'))

                $findings.Add((New-ForgeFinding -Severity Blocking -Code 'MSIX_OUT_OF_SCOPE' -Field 'ContainerType' -Message (
                    'MSIX/APPX packaging is out of scope for v1. See the roadmap in README.md.')))
                break
            }
        }

        foreach ($record in $AdditionalEvidence) {
            if ($record -isnot [EvidenceRecord]) {
                throw [System.ArgumentException]::new(
                    "AdditionalEvidence must contain EvidenceRecord objects; got '$($record.GetType().FullName)'.", 'AdditionalEvidence')
            }
            $evidence.Add($record)
        }

        # ---- Resolve ---------------------------------------------------------------------
        $merge = Merge-InstallerEvidence -Evidence $evidence.ToArray()
        foreach ($finding in $merge.Findings) { $findings.Add($finding) }

        $resolved = $merge.Resolved

        $getValue = {
            param([string] $field)
            if ($resolved.Contains($field)) { return $resolved[$field].Value }
            return $null
        }

        $info.ContainerType        = Get-ForgeEnumValue -Value (& $getValue 'ContainerType') -Type ([ContainerType])   -Default $detection.ContainerType
        $info.PayloadType          = Get-ForgeEnumValue -Value (& $getValue 'PayloadType')   -Type ([PayloadType])     -Default ([PayloadType]::Unknown)
        $info.MsiKind              = Get-ForgeEnumValue -Value (& $getValue 'MsiKind')       -Type ([MsiKind])         -Default $(
            if ($detection.ContainerType -eq [ContainerType]::Msi) { [MsiKind]::Unknown } else { [MsiKind]::NotApplicable })
        $info.Framework            = Get-ForgeEnumValue -Value (& $getValue 'Framework')     -Type ([InstallerFramework]) -Default $(
            if ($info.MsiKind -eq [MsiKind]::Native) { [InstallerFramework]::MsiNative } else { [InstallerFramework]::Unknown })
        $info.Architecture         = Get-ForgeEnumValue -Value (& $getValue 'Architecture')  -Type ([ArchitectureType]) -Default ([ArchitectureType]::Unknown)

        $info.ProductName          = & $getValue 'ProductName'
        $info.Manufacturer         = & $getValue 'Manufacturer'
        $info.ProductVersionRaw    = & $getValue 'ProductVersionRaw'
        $info.ProductCode          = & $getValue 'ProductCode'
        $info.UpgradeCode          = & $getValue 'UpgradeCode'
        $info.Language             = & $getValue 'Language'

        $info.ProductCodePresent   = [bool] (& $getValue 'ProductCodePresent')
        $info.SupportsMsiUninstall = [bool] (& $getValue 'SupportsMsiUninstall')

        $candidates = & $getValue 'FrameworkCandidates'
        if ($candidates) {
            $info.FrameworkCandidates = @(
                foreach ($candidate in @($candidates)) {
                    Get-ForgeEnumValue -Value $candidate -Type ([InstallerFramework]) -Default ([InstallerFramework]::Unknown)
                }
            )
        }

        # Preserve provider observations separately from the resolved winners. A resolved
        # winner may be a downgraded clone after a conflict; the raw records must remain
        # inspectable exactly as their providers emitted them.
        $info.Evidence         = $evidence.ToArray()
        $info.ResolvedEvidence = @($resolved.Values)
        $info.Findings         = $findings.ToArray()

        return $info
    }
}

function Test-ScaffoldOutput {
    <#
        .SYNOPSIS
            Minimal inline sanity checks over a freshly rendered scaffold directory.

        .DESCRIPTION
            Run by New-PackageScaffold immediately before it returns. This is deliberately
            the minimal subset (plan §5.6): no unresolved template tokens, every generated
            .ps1 parses, every file the manifest references exists, the detection script is
            under the ConfigMgr 32 KB limit, and the staged installer's hash matches the
            manifest. The full standalone Test-PackageScaffold cmdlet is separate future
            roadmap work, not this.

            A failure here means the renderers produced something inconsistent with their own
            manifest -- it is a self-check on PSPackageForge's output, not a judgement about
            the target application.
    #>
    [CmdletBinding()]
    [OutputType([Finding[]])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ManifestPath
    )

    $findings = [System.Collections.Generic.List[Finding]]::new()

    $textFiles = @(Get-ChildItem -LiteralPath $OutputPath -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1', '.md', '.json') })

    # ---- No unresolved template tokens in any emitted file --------------------------------
    foreach ($file in $textFiles) {
        $content = Get-Content -LiteralPath $file.FullName -Raw
        $tokenMatches = [regex]::Matches($content, '\{\{[A-Za-z0-9_]+\}\}')
        if ($tokenMatches.Count -gt 0) {
            $names = ($tokenMatches | ForEach-Object { $_.Value } | Select-Object -Unique) -join ', '
            $findings.Add((New-ForgeFinding -Severity Blocking -Code 'SCAFFOLD_UNRESOLVED_TOKEN' -Message (
                "Unresolved template token(s) survived into '{0}': {1}" -f $file.Name, $names)))
        }
    }

    # ---- Every generated .ps1 parses -------------------------------------------------------
    foreach ($file in @($textFiles | Where-Object { $_.Extension -eq '.ps1' })) {
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $parseErrors)
        if ($parseErrors -and @($parseErrors).Count -gt 0) {
            $messages = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
            $findings.Add((New-ForgeFinding -Severity Blocking -Code 'SCAFFOLD_SCRIPT_PARSE_ERROR' -Message (
                "'{0}' does not parse as valid PowerShell: {1}" -f $file.Name, $messages)))
        }
    }

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        $findings.Add((New-ForgeFinding -Severity Blocking -Code 'SCAFFOLD_MANIFEST_MISSING' -Message (
            "Expected manifest not found at '$ManifestPath'.")))
        return $findings.ToArray()
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

    # ---- Every file referenced by the manifest exists --------------------------------------
    $installerFileName = "$($manifest.Installer.Path)"
    if (-not [string]::IsNullOrWhiteSpace($installerFileName)) {
        $stagedInstaller = Join-Path $OutputPath $installerFileName

        if (-not (Test-Path -LiteralPath $stagedInstaller)) {
            $findings.Add((New-ForgeFinding -Severity Blocking -Code 'SCAFFOLD_MISSING_REFERENCED_FILE' -Message (
                "The manifest references installer '{0}', but it does not exist in the scaffold output." -f $installerFileName)))
        }
        else {
            # ---- The staged installer's SHA256 matches the manifest ------------------------
            $actualHash = (Get-FileHash -LiteralPath $stagedInstaller -Algorithm SHA256).Hash
            if ($actualHash -ne $manifest.Installer.SHA256) {
                $findings.Add((New-ForgeFinding -Severity Blocking -Code 'SCAFFOLD_HASH_MISMATCH' -Message (
                    "The staged installer's SHA256 ({0}) does not match the manifest's recorded SHA256 ({1})." -f $actualHash, $manifest.Installer.SHA256)))
            }
        }
    }

    # ---- Detection script is under the ConfigMgr 32 KB limit --------------------------------
    $detectionScriptPath = Join-Path $OutputPath 'Detect-Application.ps1'
    if (Test-Path -LiteralPath $detectionScriptPath) {
        $byteCount = [Text.Encoding]::UTF8.GetByteCount((Get-Content -LiteralPath $detectionScriptPath -Raw))
        if ($byteCount -ge 32768) {
            $findings.Add((New-ForgeFinding -Severity Blocking -Code 'SCAFFOLD_DETECTION_SCRIPT_TOO_LARGE' -Message (
                "Detect-Application.ps1 is {0} bytes, at or over the ConfigMgr 32 KB detection-script limit." -f $byteCount)))
        }
    }

    return $findings.ToArray()
}

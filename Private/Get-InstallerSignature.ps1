function Get-InstallerSignature {
    <#
        .SYNOPSIS
            Reads the Authenticode signature of an installer.

        .DESCRIPTION
            Signature status is evidence about provenance, not a deployment decision, so it
            is recorded and reported rather than acted on. An unsigned installer is a fact
            worth putting in front of a reviewer; it is not PSPackageForge's job to refuse
            one.

            Note that a signature being *valid* says the file has not been tampered with
            since signing. It says nothing about whether the signer is one you should trust,
            which is why the signer subject is surfaced rather than reduced to a boolean.

        .OUTPUTS
            SignatureInfo
    #>
    [CmdletBinding()]
    [OutputType([SignatureInfo])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $info = [SignatureInfo]::new()

    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop

        $info.Status = $signature.Status.ToString()

        if ($signature.Status -eq 'NotSigned' -or $null -eq $signature.SignerCertificate) {
            $info.IsSigned = $false
            return $info
        }

        $info.IsSigned         = $true
        $info.SignerSubject    = $signature.SignerCertificate.Subject
        $info.SignerThumbprint = $signature.SignerCertificate.Thumbprint

        if ($signature.TimeStamperCertificate) {
            # Recorded in UTC with a round-trip format so the manifest does not vary with
            # the generating machine's locale.
            $info.TimestampUtc = $signature.SignerCertificate.NotBefore.ToUniversalTime().ToString('o')
        }
    }
    catch {
        $info.IsSigned = $false
        $info.Status   = 'CheckFailed'
        Write-Verbose "Authenticode check failed for '$Path': $($_.Exception.Message)"
    }

    return $info
}

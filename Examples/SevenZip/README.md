# Example: 7-Zip 26.02 (x64)

This schema-2 example records a native MSI analysis and its reviewed package decisions. The
vendor installer is not committed. The manifest, review document, and detection script are
generated output; no installer, `Package` directory, receipt, or Intune artifact belongs in
this example.

| | |
|---|---|
| Source installer | `7z2602-x64.msi` |
| SHA256 | `DB407A4F6D4999E5C7BC00CE8A882BE94717B56E7FA68140FE3F12605D91643E` |
| Vendor download | <https://www.7-zip.org/download.html> |
| PSPackageForge | 0.2.0 preview, manifest schema 2.0 |
| Required PSADT | 4.0.6 |

The example shows `InstallerArchitecture: x64`, read from the MSI Summary Template, and
`ApplicationArchitecture: Unknown`: installer bitness does not establish the installed
application's bitness. The generated MSI install and uninstall commands include
`REBOOT=ReallySuppress`; return-code policy still records reboot-required results such as
3010 when reported by the installer.

The package is `ReviewRequired`. Review the install and uninstall commands, `System` context,
and the heuristic file detection at `%ProgramFiles%\7-Zip\7z.exe` against the vendor MSI and
a real test installation before deployment. Detection compares the file version `26.2.0.0`,
which differs from MSI ProductVersion `26.02.00.0`. The manifest records that discrepancy and
the heuristic target choice.

## Reproduce locally

On Windows, with the 0.2.0 module imported, analyze the vendor MSI and review the resulting
scaffold before packing:

```powershell
Import-Module ./PSPackageForge.psd1
psforge scaffold ./7z2602-x64.msi
# Review Output/7z2602-x64/PackageDocument.md and PackageManifest.json.
psforge pack ./Output/7z2602-x64
```

The vendor installer must be obtained separately. PSPackageForge does not download it, PSADT,
or IntuneWinAppUtil. Packing requires PSAppDeployToolkit 4.0.6 locally. See the root README for
the receipt, reuse, and recovery rules.

## Detection contract

`Detect-Application.ps1` writes nonempty output and exits 0 when detected; it exits 0 with empty
output when absent. A failure to inspect the target exits nonzero and writes an error to
STDERR. ConfigMgr treats that as unknown; Intune may treat it as not installed and retry, so
investigate detection failures.

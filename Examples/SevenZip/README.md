# Example: 7-Zip 26.02 (x64)

Generated output from a real run of `New-PackageScaffold`. This is the **native MSI
baseline**: a normal, well-behaved package with a real payload, a clean ProductCode,
standard product registration, and a directory chain that resolves cleanly.

It exists to prove the ordinary path works before any wrapper handling or known-quirk
override enters the picture. **7-Zip has no entry in `Config/known-quirks.psd1` and must
never need one.** If it ever does, the general MSI path is wrong and that is the bug to fix.

## Reproducing this

The vendor MSI is deliberately **not committed**. Download it yourself, verify the hash, and
run the scaffolder:

```powershell
Import-Module ./PSPackageForge.psd1
New-PackageScaffold -Path ./7z2602-x64.msi -OutputPath ./out
```

| | |
|---|---|
| Source installer | `7z2602-x64.msi` |
| SHA256 | `DB407A4F6D4999E5C7BC00CE8A882BE94717B56E7FA68140FE3F12605D91643E` |
| Vendor download | <https://www.7-zip.org/download.html> |
| Generated | 2026-08-07 |
| PSPackageForge | 0.1.0 (manifest schema 1.0) |
| PSADT | not applicable; `New-PSADTPackage` is not implemented yet |

`New-PackageScaffold` stages the installer alongside its output, so a full run produces a
fourth file, `7z2602-x64.msi`, which is not reproduced here.

## Files

```text
PackageManifest.json    authoritative output; everything else renders from it
PackageDocument.md      human review document
Detect-Application.ps1  detection script for ConfigMgr or Intune
```

## What this run resolved

| | |
|---|---|
| Readiness | `ReviewRequired` (the ceiling; never "ready to deploy") |
| Blocking findings | none |
| Container / payload / kind | `Msi` / `Msi` / `Native` |
| Architecture | `x64`, read from the MSI summary Template, not from the host |
| Install | `msiexec.exe /i 7z2602-x64.msi /qn` |
| Uninstall | `msiexec.exe /x {23170F69-40C1-2702-2602-000001000000} /qn` |
| Install location | `%ProgramFiles%\7-Zip` |
| Detection | file version of `%ProgramFiles%\7-Zip\7z.exe`, `Exact` `26.2.0.0` |
| Context | `System` |

Three details are worth reading the manifest for, because each is somewhere a hand-written
package commonly goes wrong.

**Uninstall is by ProductCode, never by filename.** The MSI does not exist on the client
after installation, so a filename-based uninstall returns `1619` and the deployment can
never be removed.

**Detection compares the file version, not the ProductVersion.** 7-Zip ships
`ProductVersion` `26.02.00.0` while `7z.exe` reports `26.2.0.0`. These are different values.
Detection resolves against the file, because the file is what is on disk. The manifest
records the discrepancy as `MSI_VERSION_DIFFERS_FROM_FILE`.

**Context came from two agreeing signals, not one.** `ALLUSERS=2` means per-machine when
elevated and per-user otherwise, so on its own it decides nothing, and it is recorded as
`MSI_ALLUSERS_AMBIGUOUS`. The payload resolving under `ProgramFiles64Folder` is the
signal that settles it: an unelevated per-user install cannot write there. Both are Medium
confidence individually; together they support `System`.

## Findings in this run

All informational. None blocks runnable output.

| Code | Field | Why it is recorded |
|---|---|---|
| `MSI_ALLUSERS_AMBIGUOUS` | `SelectedContext` | `ALLUSERS=2` does not determine context by itself |
| `MSI_DETECTION_TARGET_INFERRED` | `DetectionTarget` | Choosing `7z.exe` as the detection file is a heuristic, so target confidence is capped at Medium even though the directory resolved at High |
| `MSI_VERSION_DIFFERS_FROM_FILE` | `DetectionTargetVersion` | ProductVersion and file version disagree |
| `MSI_UPGRADE_TABLE_PRESENT` | `UpgradeCode` | Related products may share the UpgradeCode; this is a product family, not ConfigMgr supersedence |

`MSI_DETECTION_TARGET_INFERRED` is the honest one. The install directory is known at High
confidence, but *which executable represents the product* is a guess. 7-Zip ships several
(`7z.exe`, `7zFM.exe`, `7zG.exe`) and more than one would work. The scaffolder picks one,
says it picked one, and caps the confidence. Review it rather than trusting it.

## Detection script contract

`Detect-Application.ps1` is written for both ConfigMgr and Intune:

| State | Exit code | STDOUT |
|---|---:|---|
| Detected | `0` | non-empty |
| Not detected | `0` | empty |
| Detection mechanism failed | non-zero | error on STDERR |

A non-zero exit means the check could not be completed, **not** that the application is
absent. The platforms then diverge: ConfigMgr treats it as Unknown, while Intune evaluates
it as not-installed and may attempt a reinstall. `PackageDocument.md` states this too.

## Still required before deploying

This scaffold has not been deployed to a real ConfigMgr client. `Readiness` is
`ReviewRequired`, which means ready for testing, not ready to ship. Release validation
against a live site is a separate manual step recorded in `VALIDATION.md` when it happens.

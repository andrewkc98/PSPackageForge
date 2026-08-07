# PSPackageForge

[![CI](https://github.com/andrewkctucker/PSPackageForge/actions/workflows/ci.yml/badge.svg)](https://github.com/andrewkctucker/PSPackageForge/actions/workflows/ci.yml)
[![PowerShell 5.1 | 7](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE)](https://learn.microsoft.com/powershell/)

**An offline MECM/Intune packaging scaffolder that refuses to guess.**

Point one cmdlet at an installer and get back a packaging bundle a human can review in two
minutes: identified installer type, extracted metadata with traceable per-field provenance,
install and uninstall commands, a detection method with real values in it, a PSADT wrapper,
an `.intunewin` build step, a machine-readable manifest, and a markdown document carrying an
explicit verify-before-deploying checklist.

> **Status: in development.** See [Build progress](#build-progress).

---

## Why this exists

Packaging an application for MECM is a repetitive research task with high error rates. For
every app you rediscover the same things: is it MSI or EXE, which installer framework, what
is the silent flag, what is the product code, what is the *real* uninstall string, and what
detection method actually resolves post-install.

Get any one of them wrong and you get a deployment that appears to succeed and reports
failure (`0x87D00324`), or an uninstall that can never run (`1619`).

### The KiCad case

KiCad is an NSIS installer that registers no product GUID and installs to a **versioned**
subfolder. MECM's auto-generated uninstall command is wrong, and the failure is silent until
someone tries to remove the app.

**What MECM generates for you:**

```text
Uninstall command : msiexec /x {00000000-0000-0000-0000-000000000000} /qn
Detection          : MSI product code (auto-filled from installer metadata)
Result             : 1619 -- the package could not be opened. The MSI does not exist on
                     the client post-install, and NSIS never registered a product anyway.
```

**What PSPackageForge produces:**

```text
Install command    : KiCad-Setup.exe /S /allusers
Uninstall command  : "C:\Program Files\KiCad\10.0\Uninstall.exe" /S
Detection          : File version of C:\Program Files\KiCad\*\bin\kicad.exe
                     (wildcard, because the install path is versioned)
Install behaviour  : Install for system
Readiness          : ReviewRequired
Finding            : [Info] CONTEXT_FLAG_NOT_BEHAVIOR -- /allusers is an NSIS MultiUser
                     plugin argument. It does NOT set the MECM installation behaviour.
                     Set User Experience -> Installation behaviour -> Install for system.
```

That last finding is the whole point. `/S /allusers` alone did not fix the real deployment;
changing the MECM installation behaviour did. An installer flag and a MECM installation
behaviour are different concepts, and a tool that conflates them produces a package that
looks right and fails in the field.

---

## The design property everything else follows from

**The tool must never emit a confident wrong answer.** A scaffolder that produces a
plausible-looking but broken uninstall string is worse than no scaffolder.

Three rules follow:

1. **Facts and decisions are different things.** `InstallerInfo` answers *what is this
   file?*. `PackageSpec` answers *how should we deploy it?*. Mixing them is how a discovered
   value silently becomes a deployment choice.
2. **Every resolved field knows where it came from.** Per-field provenance, not one
   confidence label for the whole package.
3. **Low confidence has operational consequences.** An unresolved critical decision blocks
   runnable output. It does not get a default.

PSPackageForge is a **scaffolder, not a package-certification engine**. `Readiness` never
reaches "ready to deploy" — the ceiling is `ReviewRequired`. Knowing exactly where automation
ends and human validation begins is the feature.

---

## Evidence and provenance

Providers emit evidence. They never construct a finished answer.

```text
  MSI provider     ─┐
  PE provider      ─┤
  Registry / JSON  ─┼─▶  Evidence merger  ─▶  InstallerInfo  ─▶  PackageSpec resolver
  Known quirks     ─┤
  (Sandbox, later) ─┘
```

Every meaningful value carries an `EvidenceRecord`: the field, the value, the **source**, a
**confidence**, and notes.

**Merge precedence** (highest wins):

```text
UserOverride > DiscoveryJson > Registry > MsiDatabase > KnownQuirk > PeMetadata > Inferred
```

> `Registry` is ranked just below `DiscoveryJson`. A live registry read is direct observation
> of an installed product, so it outranks static MSI metadata; but an exported discovery file
> is the artefact a human reviewed and committed, so it wins on a tie. The rest of the chain
> is as specified in the design document.

When two **High**-confidence sources disagree on a **critical** field — install command,
uninstall command, install location, selected context, detection target — the merger applies
precedence, then **emits an `EVIDENCE_CONFLICT` finding and downgrades that field to Medium**.
It never resolves silently.

Corroboration is not conflict: two sources reporting the same ProductCode in different letter
case agree. Two sources reporting `1.0` and `1.0.0.0` do **not** — version padding is a real
difference, and hiding it would hide exactly the question you need to answer.

---

## Correctness details that matter

**Detection scripts distinguish "absent" from "broken".** One contract serves both MECM and
Intune:

| State | Exit code | STDOUT |
|---|---|---|
| Detected | `0` | any non-empty output |
| Not detected | `0` | nothing |
| Detection mechanism failed | non-zero | error to STDERR |

Non-zero does **not** mean absent — it means the detection itself failed, which ConfigMgr
treats as unknown. Using `exit 1` for "not detected" produces misleading compliance data
across a fleet.

**Commands are structured, never strings.** Nothing internal carries
`"C:\setup.exe /S /allusers"`. A `CommandSpec` holds executable, argument list, working
directory, and expected exit codes; rendering to a quoted string happens exactly once, at the
output boundary.

**Raw versions are preserved.** `ProductVersionRaw` is exactly what the installer reported.
Normalisation happens only at a render boundary that needs it, and records a finding when
padding was applied. Windows Installer's `ProductVersion` comparison honours only the first
three numeric fields.

**Architecture is modelled, never inferred from the host.** Whether a detection script runs
32-bit is an explicit deployment-type option, not a default to architect around. Generated
detection scripts are redirection-safe regardless.

**`Win32_Product` is never used.** Querying it triggers a reconfigure of every installed MSI
on the machine. This warning appears in every generated document.

---

## The four regression cases

The first is the *normal* path and is built first — the other three only mean something once
the normal case works.

| App | Proves |
|---|---|
| **7-Zip** (MSI) | Native MSI resolution, architecture handling, and that a normal app produces `ReviewRequired` with no blocking findings. No quirk entry — if 7-Zip needs one, the general MSI path is wrong. |
| **Firefox ESR** | `ContainerType = Msi`, `PayloadType = Exe`, `MsiKind = Wrapper`. ProductCode present but `SupportsMsiUninstall = $false`. Offline MSI analysis must not claim it found `firefox.exe` in the `File` table — the wrapper has no such payload. |
| **KiCad** (NSIS) | Versioned-path resolution, and that an installer flag is not the same concept as a MECM installation behaviour. |
| **Obsidian** (Squirrel) | Genuine per-user context, only-when-logged-on, and per-user registry discovery. |

---

## Requirements

- Windows. MSI parsing, registry views, and Authenticode have no cross-platform equivalent
  worth faking.
- **Windows PowerShell 5.1 or PowerShell 7.** Both are tested in CI. 5.1 is non-negotiable —
  it is what MECM environments actually run.
- Optional: `PSAppDeployToolkit` v4 (pinned) for `New-PSADTPackage`;
  `IntuneWinAppUtil.exe` for `New-IntuneWinPackage`. Neither is downloaded automatically.

**The ConfigMgr console is not required and must not be installed.** The module never imports
or depends on `ConfigurationManager.psd1`.

```powershell
git clone https://github.com/andrewkctucker/PSPackageForge
Import-Module ./PSPackageForge/PSPackageForge.psd1
```

Run the same checks CI runs:

```bash
./build.ps1
```

---

## Build progress

Implemented against the locked v1 scope:

- [x] Module skeleton, PSScriptAnalyzer settings, CI on 5.1 + 7
- [x] Type contract — `EvidenceRecord`, `InstallerInfo`, `PackageSpec`, `Finding`, `CommandSpec`
- [x] Evidence merger, precedence, and `EVIDENCE_CONFLICT` behaviour
- [ ] Native MSI provider and `File → Component → Directory` path resolution
- [ ] `PackageSpec` resolver and `ConvertTo-CommandString`
- [ ] Detection renderer
- [ ] Manifest, document, inline validation
- [ ] Wrapper-MSI detection (Firefox ESR)
- [ ] `Get-InstalledAppInfo` and the discovery contract
- [ ] EXE framework evidence and argument profiles
- [ ] KiCad and Obsidian regressions
- [ ] `New-PSADTPackage`, `New-IntuneWinPackage`

---

## Roadmap — deliberately not in v1

Every item below is a good idea that was deferred on purpose. A visible, reasoned roadmap
reads better than a tool that tried to do everything.

1. **`-DiscoverInSandbox`** — Windows Sandbox empirical discovery: snapshot, install
   silently, re-snapshot, diff. The headline feature when it lands. The provider
   architecture exists so it drops in without touching downstream stages.
2. **`Test-PackageScaffold`** — standalone static validator. v1 does a minimal subset inline.
3. **`MecmDeploymentSpec.json` / `IntuneWin32Spec.json`** — target-specific renderers off the
   manifest. Cheap once the manifest exists, which is exactly why they can wait.
4. **winget-pkgs fallback** — community metadata as an evidence provider when local detection
   returns `Unknown`.
5. **`New-CMApplicationFromScaffold`** — MECM Application creation. Least demonstrable, needs
   console plus site plus credentials, highest risk.
6. **PSADT v3 templates.**
7. **Formal JSON Schema validation.** v1 versions both contracts but validates structurally.
8. **Loading unloaded `HKEY_USERS` hives** for profiles that are not signed in.

**Out of scope entirely:** Microsoft Graph / Intune Win32 LOB upload, MSIX repackaging,
App-V, driver packages, MSP patch handling, a GUI, and automatic tooling downloads.

---

## Opsec

No employer infrastructure identifiers appear anywhere in this repository — no site server
FQDN, site code, console folder paths, internal hostnames, usernames, or domains.

`Config/settings.example.psd1` ships placeholders only. Real values belong in a gitignored
`Config/settings.psd1`. Generated discovery JSON deliberately omits hostname, username, and
domain so it can be committed to `Examples/`.

`Examples/` contains **generated output only**. Vendor installers are never committed; each
example records the source filename, SHA256, vendor download URL, generation date, and tool
versions so it is reproducible without redistributing third-party software. CI enforces this.

## Licence

MIT. See [LICENSE](LICENSE).

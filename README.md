# PSPackageForge

[![CI](https://github.com/andrewkc98/PSPackageForge/actions/workflows/ci.yml/badge.svg)](https://github.com/andrewkc98/PSPackageForge/actions/workflows/ci.yml)
[![PowerShell 5.1 | 7](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE)](https://learn.microsoft.com/powershell/)

PSPackageForge is an offline PowerShell scaffolder for MECM and Intune application packaging.

Give it an installer and it builds a reviewable packaging bundle containing:

- installer identification and metadata
- per-field evidence and provenance
- install and uninstall commands
- application detection
- PSADT package scaffolding
- an `.intunewin` build step
- a machine-readable package manifest
- package documentation with a verification checklist

> **Status: v1 functional scope implemented.** See [Future roadmap](#future-roadmap-remaining-work) for remaining work.

---

## Why this exists

Application packaging involves a lot of repeated investigation.

For most applications you need to determine:

- whether the installer is MSI or EXE
- which installer framework it uses
- the correct silent arguments
- whether a usable product code exists
- the actual uninstall command
- where the application installs
- which detection method will work after installation
- whether the application needs system or user context

A mistake in any of these can result in an installation that completes successfully but fails detection, or an uninstall command that only fails once MECM tries to use it.

Typical examples include `0x87D00324` for failed post-install detection and `1619` when an invalid MSI uninstall path is used.

### The KiCad case

KiCad is one of the applications that led to this project.

It uses an NSIS installer, has no usable MSI product registration, and installs into a versioned directory.

A generated package that assumes MSI-style uninstall and detection will therefore be wrong.

Example:

```text
Uninstall command : msiexec /x {00000000-0000-0000-0000-000000000000} /qn
Detection          : MSI product code
Result             : 1619
```

The MSI referenced by that command does not exist on the installed client, and NSIS did not register the application as a Windows Installer product.

PSPackageForge instead produces information such as:

```text
Install command    : KiCad-Setup.exe /S /allusers
Uninstall command  : "C:\Program Files\KiCad\10.0\Uninstall.exe" /S
Detection          : File version of C:\Program Files\KiCad\*\bin\kicad.exe
Install behaviour  : Install for system
Readiness          : ReviewRequired
Finding            : [Info] CONTEXT_FLAG_NOT_BEHAVIOR
```

The related finding records that `/allusers` is an NSIS MultiUser plugin argument. MECM's installation behaviour still needs to be configured separately as **Install for system**.

This distinction matters because the installer arguments and the MECM execution context are separate settings.

---

## Design

The project follows three main rules.

### Facts and deployment decisions are separate

`InstallerInfo` describes the installer itself.

`PackageSpec` describes how the application should be packaged and deployed.

Keeping these separate prevents installer metadata from automatically becoming a deployment decision.

### Every important value has provenance

Package-wide confidence is too broad for packaging work.

Different values may come from different sources, so PSPackageForge tracks evidence per field.

For example:

```text
ProductVersion    -> MSI database
Architecture      -> PE metadata
UninstallCommand  -> reference-machine discovery
InstallContext    -> known application behaviour
```

### Low-confidence decisions require review

Critical unresolved values affect package readiness.

A package with unresolved install commands, uninstall commands, context, or detection information is kept in a state that requires additional input.

The highest readiness state produced by PSPackageForge is:

```text
ReviewRequired
```

The generated package still needs to be tested before deployment.

---

## Evidence and provenance

Discovery providers return evidence that is merged before the final package specification is resolved.

```text
MSI provider     ─┐
PE provider      ─┤
Registry / JSON  ─┼─▶ Evidence merger ─▶ InstallerInfo ─▶ PackageSpec resolver
Known quirks     ─┤
Sandbox, later   ─┘
```

Each meaningful value is associated with an `EvidenceRecord` containing:

```text
Field
Value
Source
Confidence
Notes
```

Current evidence precedence is:

```text
UserOverride
    >
DiscoveryJson
    >
Registry
    >
MsiDatabase
    >
KnownQuirk
    >
PeMetadata
    >
Inferred
```

A live registry value represents direct observation from an installed application. Exported discovery data ranks slightly higher because it is intended to be reviewed before being reused for package generation.

If two High-confidence sources disagree on a critical field, precedence still determines which value is selected, but PSPackageForge also:

1. emits an `EVIDENCE_CONFLICT` finding
2. records the disagreement
3. downgrades the selected field to Medium confidence

Critical fields include:

```text
InstallCommand
UninstallCommand
InstallLocation
SelectedContext
DetectionTarget
```

Equivalent values from multiple sources count as corroboration.

Values such as `1.0` and `1.0.0.0` remain distinct so that version normalization stays visible.

---

## Detection scripts

Generated detection scripts use the same basic contract for MECM and Intune.

| State | Exit code | STDOUT |
|---|---:|---|
| Detected | `0` | Non-empty |
| Not detected | `0` | Empty |
| Detection failed | Non-zero | Error |

An absent application is therefore different from a detection script that could not complete its check.

Detection failure is reported as an error rather than as normal application absence.

---

## Command handling

Commands are represented internally as structured data.

Instead of storing:

```text
"C:\setup.exe /S /allusers"
```

PSPackageForge uses a `CommandSpec` containing values such as:

```text
Executable
ArgumentList
WorkingDirectory
ExpectedExitCodes
```

The command is converted into its final quoted string when an output renderer needs it.

This keeps quoting and argument handling in one place.

---

## Version handling

`ProductVersionRaw` preserves the value reported by the installer.

Normalization is performed only when an output format requires it.

If a version is changed for rendering, PSPackageForge records a finding so the generated output can be traced back to the original value.

Windows Installer `ProductVersion` comparisons use the first three numeric fields, which is handled separately from file-version detection.

---

## Architecture and registry views

Application architecture is part of the package model.

PSPackageForge tracks:

```text
x86
x64
Arm64
Neutral
Unknown
```

Architecture is used when resolving filesystem paths, registry views, requirements, and detection settings.

The architecture of the packaging workstation is not used as a substitute for application architecture.

Detection-script 32-bit execution is treated as an explicit deployment setting.

---

## Win32_Product

PSPackageForge does not use:

```powershell
Get-CimInstance Win32_Product
Get-WmiObject Win32_Product
```

Application discovery uses the Windows uninstall registry instead.

The generated package documentation also includes a warning about `Win32_Product`, since querying it can trigger Windows Installer consistency checks against installed MSI applications.

---

## Regression applications

Four applications are used to exercise different parts of the packaging model.

| Application | Coverage |
|---|---|
| **7-Zip MSI** | Native MSI resolution, architecture handling, and the normal MSI path. It has no quirk entry. |
| **Firefox ESR** | MSI wrapper containing an EXE payload. Exercises `ContainerType = Msi`, `PayloadType = Exe`, and `MsiKind = Wrapper`. |
| **KiCad** | NSIS, versioned installation paths, and the distinction between installer arguments and MECM installation behaviour. |
| **Obsidian** | Per-user Squirrel installation, logged-on-user requirements, and per-user registry discovery. |

These are current deterministic regression cases covering the supported v1 paths; they are not a planned implementation sequence.

Firefox ESR covers wrapper-MSI handling.

KiCad and Obsidian cover EXE packaging where installation location and execution context require additional handling.

---

## Requirements

Operational use targets Windows. PowerShell 7 on Ubuntu verifies portable build and analyzer behaviour plus deterministic tests; it is not an operational target for the package workflows. Live installed-application registry discovery is Windows-only.

Verified PowerShell runtimes:

- Windows PowerShell 5.1
- PowerShell 7 on Ubuntu (portable build, analyzer, and deterministic-test verification)

Windows PowerShell 5.1 remains supported because it is still widely used in MECM environments.

Optional tooling:

- `PSAppDeployToolkit` v4 for `New-PSADTPackage`
- `IntuneWinAppUtil.exe` for `New-IntuneWinPackage`

Optional tools are not downloaded automatically.

The ConfigMgr console is not required. PSPackageForge does not depend on `ConfigurationManager.psd1`.

### Clone and import

```powershell
git clone https://github.com/andrewkc98/PSPackageForge
Import-Module ./PSPackageForge/PSPackageForge.psd1
```

## Quick Start: the `psforge` workflow

The `psforge` command keeps discovery, review, and packaging as separate steps. It does
not download tools, deploy applications, or declare an untested package ready to ship.

### 1. Discover (reference machine)

Run discovery on a Windows reference machine where the application is installed. The
uninstall registry is read across the 32-bit and 64-bit machine views plus the current
user view. Each matching registration is returned as a separate match with its own
evidence and findings; discovery does not merge registrations or select a match.

```powershell
psforge discover 'KiCad*' -Output ./KiCad.discovery.json
```

The long-form equivalent is:

```powershell
Invoke-PackageForge -Action discover -Path 'KiCad*' -OutputPath ./KiCad.discovery.json
```

Review the match IDs in the JSON. Use `-Match`/`-DiscoveryMatchId` on scaffold only when
discovery returned multiple matches; a single match can be selected automatically. An
unresolved or ambiguous registration remains a finding and is not turned into guessed
install, uninstall, location, context, or detection data.

### 2. Scaffold (installer analysis and review pause)

Point scaffold at an existing installer. The default output is `Output/<basename>` with
the installer extension removed; an explicit `-Output`/`-OutputPath` keeps the path you
provided. The command writes the manifest, review document, staged installer, and a
detection script when detection resolves above Low confidence.

```powershell
psforge scaffold ./KiCad-Setup.exe -Discovery ./KiCad.discovery.json -Match $matchId
```

Without discovery data, the positional form is sufficient:

```powershell
psforge scaffold ./7z2602-x64.msi
```

The long-form equivalent is:

```powershell
Invoke-PackageForge -Action scaffold -Path ./KiCad-Setup.exe -DiscoveryPath ./KiCad.discovery.json -DiscoveryMatchId $matchId
```

Native MSI analysis uses the MSI database, including ProductCode and resolved file/directory
evidence. EXE analysis is signature-based: recognized NSIS, Inno Setup, Squirrel, and WiX
Burn profiles receive only their known installer arguments; unknown, ambiguous, or
InstallShield EXEs retain findings and require review. A wrapper MSI is treated as an MSI
container with an EXE payload, not as evidence of a native MSI install or uninstall.

This is a mandatory review/readiness pause. Read `PackageDocument.md` and
`PackageManifest.json`, verify commands, context, location, detection, and findings, and
resolve any `NeedsInput` state before packing. PSPackageForge preserves unresolved
discovery and EXE findings rather than manufacturing evidence. Pack accepts the reviewed
`ReviewRequired` manifest; it stops on `NeedsInput`.

### 3. Pack (reviewed scaffold root)

Pack the scaffold root, not the raw installer:

```powershell
psforge pack ./Output/KiCad-Setup
```

The long-form equivalent is:

```powershell
Invoke-PackageForge -Action pack -Path ./Output/KiCad-Setup
```

Pack uses the exact PSAppDeployToolkit 4.0.6 version recorded by the manifest. The module
must already be available locally (or be supplied with the advanced
`-PSADTModulePath` option); PSPackageForge never downloads or upgrades it. A complete
existing `Package` is reused only after read-only structure and SHA-256 checks. Partial or
mismatched content is refused and is not deleted or replaced.

`IntuneWinAppUtil.exe` is resolved locally from an explicit `-IntuneWinAppUtilPath`, the
optional repository `Config/settings.psd1` setting, or exactly one match on `PATH`. An
unavailable or ambiguous utility produces `InstructionsOnly`, including the manual
`Build-IntuneWin.ps1` instruction, with no fabricated artifact. When the utility succeeds,
the final `.intunewin` and its SHA-256 are returned; otherwise `IntuneWinPath` and `SHA256`
remain null. Intune's source is the PSADT `Package` directory and its setup entry point,
never the raw installer.

### Run the project checks

```powershell
./build.ps1
```

This runs the same core checks used by CI.

### Advanced primitive: discover an installed application

For installers that cannot reveal their installed layout or vendor uninstaller offline,
run discovery on a Windows reference machine where the application is already installed:

```powershell
$discovery = Get-InstalledAppInfo -DisplayNameLike 'KiCad*' `
    -OutputPath ./KiCad.discovery.json
$discovery.Matches | Select-Object MatchId, DisplayName, RegistryIdentity
```

Discovery reads the 32-bit and 64-bit machine uninstall registry plus the current user's
uninstall registry. It does not query Windows Installer inventory through WMI. Every match
stays separate, carries per-field `Registry` provenance, and records missing or ambiguous
values as findings instead of silently choosing an answer. Profiles that are not currently
loaded remain outside v1 discovery scope.

Pass the reviewed document into scaffold generation. A document with one match is selected
automatically; when several applications matched, select the intended one by its stable ID:

```powershell
New-PackageScaffold -Path ./KiCad-Setup.exe -OutputPath ./Output `
    -DiscoveryData ./KiCad.discovery.json `
    -DiscoveryMatchId $discovery.Matches[0].MatchId
```

Imported observations are attributed to `DiscoveryJson`, which ranks above a live registry
read because the exported document is an explicit, reviewable handoff. User overrides still
rank above imported discovery evidence.

### Advanced primitives and renderers

These lower-level commands are useful for overrides, MECM rendering, and inspecting a
particular stage. They use a reviewed scaffold; preview file-writing renderers with
`-WhatIf` before choosing an output location:

```powershell
$scaffold = New-PackageScaffold -Path ./setup.exe -OutputPath ./Output
$info = Get-InstallerInfo -Path ./setup.exe
New-DetectionMethod -DetectionSpec $scaffold.PackageSpec.DetectionSpec[0] -OutputPath ./Output/Detection -WhatIf
New-PackageDocument -ManifestPath $scaffold.ManifestPath -WhatIf
New-MecmDeploymentSpec -ManifestPath $scaffold.ManifestPath `
    -OutputPath ./Output/MecmDeploymentSpec.json -ContentSourcePath "\\server\share\App"
```

`Get-InstallerInfo` inspects a payload and returns evidence-backed installer facts. The other commands render reviewed inputs; they do not rediscover or invent deployment decisions.

### Advanced primitive: generate PSADT content

After `New-PackageScaffold` has produced a reviewed manifest, generate the PSADT content
root directly with:

```powershell
New-PSADTPackage -ManifestPath ./Output/PackageManifest.json
```

The default output is `Package/` beside the manifest. PSPackageForge requires the exact
PSAppDeployToolkit version recorded in the manifest (`4.0.6` for schema v1), calls its native
`New-ADTTemplate`, copies the hash-verified installer into `Package/Files`, and renders the
manifest's structured payload commands into the PSADT install and uninstall phases. It never
downloads or silently upgrades PSADT.

MECM deployment specifications invoke this package through the stable
`Invoke-AppDeployToolkit.exe` entry point; the vendor payload commands remain authoritative
inside `PackageManifest.json`. For an intentional refresh of an existing package root, use
this primitive deliberately rather than the safe `psforge pack` reuse path.

---

### EXE framework profiles

EXE analysis is deliberately conservative and signature-based. Every string marker is
scanned in both ASCII and UTF-16LE; `.wixburn` is matched only as an exact PE section. The
supported signatures and profiles are:

| Signature | Framework | Install arguments |
|---|---|---|
| ASCII or UTF-16LE `NullsoftInst` | NSIS | `/S` |
| ASCII or UTF-16LE `Inno Setup Setup Data` | Inno Setup | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-` |
| ASCII or UTF-16LE `InstallShield Setup Launcher` | InstallShield | no inferred command; review required |
| ASCII or UTF-16LE `SquirrelSetup`, `SquirrelAwareVersion`, or `Installer for Squirrel-based applications` | Squirrel | `--silent` |
| exact PE section `.wixburn` | WiX Burn | `/quiet /norestart` |

A unique recognized signature emits a framework profile. Unknown EXEs and ambiguous matches
fail closed: they retain candidate evidence and do not receive an install command. InstallShield
is recognized but intentionally refuses an argument profile with
`EXE_ARGUMENT_PROFILE_UNRESOLVED`.

These profiles never choose installation context, install location, uninstall behavior, or
detection. KiCad and Obsidian regression fixtures prove this separation by taking installer
arguments from PE evidence and context, uninstall, location, and detection from reviewed
DiscoveryJson evidence.

Every inferred EXE install command records only expected exit code `0` and adds
`EXE_EXIT_CODES_UNVERIFIED`. Verify the vendor's exit-code contract before deployment.
Squirrel also records `SQUIRREL_COMPLETION_UNVERIFIED`.

### Advanced primitive build flow

The dispatcher workflow above is the normal path. For explicit stage-by-stage control,
the equivalent primitive flow is:

```powershell
$scaffold = New-PackageScaffold -Path ./KiCad-Setup.exe -OutputPath ./Output `
    -DiscoveryData ./KiCad.discovery.json
New-PSADTPackage -ManifestPath $scaffold.ManifestPath
New-IntuneWinPackage -OutputPath ./Output
```

The scaffold writes the authoritative `PackageManifest.json`, staged installer, and
detection script. `New-PSADTPackage` creates `Output/Package/`, copies the
hash-checked installer to `Package/Files/`, and renders the PSADT entry point and deployment
script. The Intune command uses `Package/` as its source and writes the accepted artifact as
`Output/IntuneWin/Invoke-AppDeployToolkit.intunewin`; `Build-IntuneWin.ps1` is written
beside the manifest as a repeatable manual build instruction. In the result object, `OutputPath` is the `IntuneWin/` output directory and `IntuneWinPath` is the built artifact file; `IntuneWinPath` is null for `InstructionsOnly` and `-WhatIf` results.

`New-IntuneWinPackage` resolves `IntuneWinAppUtil.exe` in this order: explicit
`-IntuneWinAppUtilPath`, optional repository-local `Config/settings.psd1` setting, or
exactly one application found on `PATH`. Zero matches produce unavailable; multiple matches
produce an ambiguity finding. It never downloads or installs the utility. When unavailable or
ambiguous, it returns `Status = InstructionsOnly` after writing the portable build script,
with no fabricated artifact. A successful build requires exit code zero and exactly one
non-empty `Invoke-AppDeployToolkit.intunewin`; its SHA-256 is returned.

## Build progress

Current v1 progress:

- [x] Module skeleton, PSScriptAnalyzer settings, CI on Windows PowerShell 5.1
- [x] PowerShell 7 implementation and CI verification
- [x] Type contract: `EvidenceRecord`, `InstallerInfo`, `PackageSpec`, `Finding`, `CommandSpec`
- [x] Evidence merger, precedence, and `EVIDENCE_CONFLICT` handling
- [x] Native MSI provider and `File → Component → Directory` path resolution
- [x] `PackageSpec` resolver and `ConvertTo-CommandString`
- [x] Detection renderer with detected, absent, and failure semantics
- [x] Authoritative `PackageManifest.json` generation and core scaffold orchestration
- [x] Package documentation and inline scaffold validation
- [x] Firefox ESR wrapper regression and known-quirk integration
- [x] `Get-InstalledAppInfo` and discovery-data contract
- [x] EXE framework evidence and argument profiles
- [x] KiCad and Obsidian regression cases
- [x] `New-MecmDeploymentSpec` and `MecmDeploymentSpec.json`
- [x] `New-PSADTPackage`
- [x] `New-IntuneWinPackage`

---

## Future roadmap (remaining work)

The following items are planned outside the current v1 scope.

### Windows Sandbox discovery

```powershell
-DiscoverInSandbox
```

The planned workflow is:

```text
snapshot
install silently
snapshot again
compare changes
```

Sandbox discovery will use the same evidence-provider interface as the existing discovery methods.

### Standalone package validation

```powershell
Test-PackageScaffold
```

v1 performs a smaller set of validation checks during package generation. A dedicated validator is planned separately.

### Future deployment specifications

The v1 commands `New-MecmDeploymentSpec` and `New-IntuneWinPackage` are implemented; the planned item in this subsection is the separate `IntuneWin32Spec.json` contract.

Machine-readable deployment specifications generated from the package manifest:

```text
MecmDeploymentSpec.json    (implemented: New-MecmDeploymentSpec)
IntuneWin32Spec.json       (planned)
```

`New-MecmDeploymentSpec` renders a ConfigMgr Application/DeploymentType-shaped
specification from an existing `PackageManifest.json`. Organization facts that no
installer evidence can determine -- the content-source UNC path and real install
runtimes -- are operator parameters; when omitted they are emitted as `null` (or the
ConfigMgr platform default of 120 minutes for the maximum runtime) together with a
`Finding` in the specification itself, never silently guessed.

### winget-pkgs evidence provider

Community package metadata may be used as an additional evidence source when local discovery cannot identify an installer.

### MECM application creation

```powershell
New-CMApplicationFromScaffold
```

Direct MECM application creation is planned after the offline package model is established.

This feature will require the ConfigMgr console, a site connection, and the appropriate credentials.

### PSADT v3 templates

PSADT v4 is the current target. v3 compatibility may be added later.

### Formal JSON Schema validation

v1 versions the package and discovery contracts and performs structural validation.

Formal JSON Schema validation is planned for a later release.

### Unloaded HKEY_USERS profiles

Current per-user discovery covers available user registry data.

Loading registry hives for profiles that are not currently signed in is planned separately.

---

## Out of scope

The following are outside the project scope:

- Microsoft Graph upload of Intune Win32 applications
- MSIX repackaging
- App-V
- driver packages
- MSP patch handling
- GUI development
- automatic tooling downloads

---

## Repository safety

Employer infrastructure details are excluded from the repository.

This includes:

- site server FQDNs
- site codes
- internal hostnames
- console folder paths
- usernames
- internal domains

`Config/settings.example.psd1` contains placeholder values.

Local settings belong in:

```text
Config/settings.psd1
```

That file is excluded from Git.

Generated discovery JSON also omits hostname, username, and domain information so example discovery data can be committed safely.

---

## Examples

`Examples/` contains generated package output.

Vendor installers are excluded from the repository.

Each example records:

```text
source installer filename
SHA256
vendor download URL
generation date
PSPackageForge version
tool versions
```

This keeps the examples reproducible without storing third-party installer binaries in the repository.

CI checks for this as part of the project validation.

---

## Licence

MIT. See [LICENSE](LICENSE).

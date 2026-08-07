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

> **Status: in development.** See [Build progress](#build-progress).

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

7-Zip is implemented first because it represents the standard MSI case.

Firefox ESR then tests wrapper-MSI handling.

KiCad and Obsidian cover two common EXE packaging cases where installation location and execution context require additional handling.

---

## Requirements

PSPackageForge currently targets Windows.

Supported PowerShell versions:

- Windows PowerShell 5.1
- PowerShell 7

Both are tested in CI.

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

### Run the project checks

```powershell
./build.ps1
```

This runs the same core checks used by CI.

---

## Build progress

Current v1 progress:

- [x] Module skeleton, PSScriptAnalyzer settings, CI on PowerShell 5.1 and 7
- [x] Type contract: `EvidenceRecord`, `InstallerInfo`, `PackageSpec`, `Finding`, `CommandSpec`
- [x] Evidence merger, precedence, and `EVIDENCE_CONFLICT` handling
- [x] Native MSI provider and `File → Component → Directory` path resolution
- [ ] `PackageSpec` resolver and `ConvertTo-CommandString`
- [ ] Detection renderer
- [ ] Manifest, documentation, and inline validation
- [ ] Wrapper-MSI detection for Firefox ESR
- [ ] `Get-InstalledAppInfo` and discovery-data contract
- [ ] EXE framework evidence and argument profiles
- [ ] KiCad and Obsidian regression cases
- [ ] `New-PSADTPackage`
- [ ] `New-IntuneWinPackage`

---

## Roadmap

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

### MECM and Intune deployment specifications

Planned machine-readable output:

```text
MecmDeploymentSpec.json
IntuneWin32Spec.json
```

These will be generated from the package manifest.

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

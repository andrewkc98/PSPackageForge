# Test fixtures — provenance

Everything in this directory is **built by us from source that is committed alongside it**.
No third-party installer binary is ever committed to this repository (see the repository
README, Opsec section). CI enforces that rule.

These fixtures are committed rather than generated at test time on purpose. Building an MSI
during every test run is unnecessary work the suite would pay for on every CI run for no
benefit — reviewers care about the fixture's declared shape, not about watching it get built.
A handful of tiny MSIs built once give the suite a deterministic spine that runs identically
on a laptop and on `windows-latest`.

Two build approaches are used, and which one applies is documented per fixture below:

  * `native-clean.msi` is built with the WiX toolset from a committed `.wxs` source.
  * `wrapper-style.msi` is built directly against the `WindowsInstaller` COM automation
    API — the same API the module itself uses to *read* an MSI — from a committed
    PowerShell generator script, with **no WiX dependency**. See that fixture's section
    below for why.

CI never downloads vendor installers. Real-vendor validation is a separate manual release
step against pinned versions with recorded SHA256 hashes.

---

## `native-clean.msi`

The spine of the whole suite. A minimal but genuinely *native* MSI: real payload, a clean
`ProductCode`, standard product registration, and a `File → Component → Directory` chain that
resolves to a fixed path. It exists so the normal MSI path can be proven correct before any
wrapper handling or known-quirk override exists.

| | |
|---|---|
| Source | [`clean-native.wxs`](clean-native.wxs) (committed) |
| Built with | WiX Toolset v4 (`wix build`) |
| Size | 32,768 bytes |
| SHA256 | `5D57B41102A394A50F4312EF538BF4DC811C170AA9603ACA64BBFCA464F0CBAE` |
| ProductName | `Fixture Native` |
| Manufacturer | `PSPackageForge Fixtures` |
| ProductVersion | `1.0.0.0` |
| ProductCode | `{B67274A8-A56D-4C2E-B1A0-7A59F5433BD2}` |
| UpgradeCode | `{F9ED75A9-DF56-47DD-B8F4-8792B55C3C27}` |
| Install path | `[ProgramFilesFolder]\FixtureNative\dummy.exe` |

Rebuild with:

```bash
wix build clean-native.wxs -out native-clean.msi
```

> **Note on `ProductCode`.** WiX generates a fresh `ProductCode` on each build unless it is
> pinned in the source. The value above is the one in the committed binary. If you rebuild
> and the hash changes, update this file — tests that assert on the ProductCode read it from
> here, not from a hard-coded literal elsewhere.

### `dummy.exe`

A zero-byte placeholder that exists only to give `MainComponent` a `KeyPath` so the `File`
table has a row to resolve. It is deliberately **not** a real PE file and carries **no
version resource** — which makes it a useful negative case: the `File` table containing a row
does not mean a version is available, and the MSI provider must downgrade confidence rather
than invent one.

---

## `wrapper-style.msi`

An MSI shaped like Mozilla's Firefox ESR package: a `ProductCode` present in the `Property`
table, an executable stub in the `Binary` table, a `CustomAction` of type `3074` (base type
`2` — "run an EXE from the `Binary` table" — plus deferred-execution and no-impersonate
flags, Firefox ESR's actual real-world value) that launches it, and **no `File` table at
all**. It exists to prove that PSPackageForge sets `MsiKind = Wrapper` and
`SupportsMsiUninstall = $false` even though `ProductCodePresent` is `$true`, that it derives
**no** `InstallLocation` or `DetectionTarget` from the wrapper's `Directory` table (which
describes where the payload is *extracted*, not where the product is *installed*), and that
it never attempts `msiexec /x` against it.

| | |
|---|---|
| Source / generator | [`New-WrapperFixture.ps1`](New-WrapperFixture.ps1) (committed) |
| Built with | `WindowsInstaller.Installer` COM automation, directly — **no WiX** |
| ProductName | `PSPackageForge Wrapper Fixture` |
| Manufacturer | `PSPackageForge Project` |
| ProductVersion | `1.0.0.0` |
| ProductCode | `{DEADBEEF-0000-4000-8000-000000000001}` |
| UpgradeCode | `{DEADBEEF-0000-4000-8000-000000000002}` |

Rebuild with:

```powershell
.\Tests\Fixtures\New-WrapperFixture.ps1
```

### Why COM instead of WiX (supersedes the earlier plan)

The original plan for this fixture called for a second `.wxs` source built with WiX, the
same way `native-clean.msi` is built. That plan is superseded. `New-WrapperFixture.ps1`
builds the database directly against the `WindowsInstaller.Installer` COM automation API —
the identical API `Private\Providers\Read-MsiDatabase.ps1` uses to *read* an MSI — issuing
`CREATE TABLE` / `INSERT` statements through `Database.OpenView(...).Execute()` for the
`Property`, `Binary`, `CustomAction`, `InstallExecuteSequence` and `Directory` tables, and
deliberately creating no `File` or `Component` table at all (`Read-MsiDatabase` treats an
absent table as an empty collection, not an error, so "absent" is the correct way to express
"zero rows" here).

Two reasons this fixture does not need WiX:

  1. **No toolchain install.** A wrapper MSI has no compiled payload, no cabinet, and uses
     no MSI linker feature WiX would add value for — it is a dozen table rows and a summary
     stream, which raw `INSERT` statements express directly.
  2. **Provenance.** The committed generator script *is* this fixture's provenance, read top
     to bottom, the same role `clean-native.wxs` plays for `native-clean.msi`.

**Determinism.** Every logical value the generator writes (every `Property` row, the
`CustomAction`, the `Binary` stream bytes, every `SummaryInformation` property it sets) is a
fixed literal, so the fixture's *table contents* reproduce exactly on every regeneration —
verified by running `Get-InstallerInfo` against a freshly regenerated copy and confirming
identical evidence and findings. The compiled file's raw bytes are **not** guaranteed
byte-identical across regenerations: the OLE2 compound-file storage layer Windows Installer
persists to stamps its own internal directory-entry timestamps that this automation API does
not expose control over. This is a documented, accepted gap — the fixture is committed once
and is not diffed byte-for-byte on rebuild — not a hard determinism gate.

### What tests assert against it

`Tests\Unit\WrapperFixture.Tests.ps1` covers, end to end against the committed file:

  * `Get-InstallerInfo` through the public boundary: `ContainerType = Msi`,
    `MsiKind = Wrapper`, `PayloadType = Exe`, `SupportsMsiUninstall = $false`,
    `ProductCodePresent = $true`, an `MSI_WRAPPER_DETECTED` warning, an
    `MSI_PAYLOAD_NOT_INTROSPECTABLE` info finding, and no resolved `InstallLocation` or
    `DetectionTarget`.
  * Container detection: the file's real bytes are an OLE2 compound document, matching its
    `.msi` extension, with no `CONTAINER_EXTENSION_MISMATCH`.
  * `Resolve-PackageSpec`: `UNINSTALL_COMMAND_UNRESOLVED` and `DETECTION_UNRESOLVED` stay
    `Blocking`, and `Readiness` stays `NeedsInput` — the honest refusal, end to end.
  * That the fixture classifies `Wrapper` from its MSI table shape alone, matching no entry
    in `Config\known-quirks.psd1` — its `ProductName` and `UpgradeCode` are deliberately
    unrelated to that file's Firefox ESR entry, so a passing suite proves the classification
    rule, not a quirk filling in the answer.

## `framework-stubs/`

*Not yet built — build order step 11.*

Small synthetic PE files carrying the identification signatures of each supported installer
framework (`NullsoftInst`, `Inno Setup Setup Data`, `InstallShield`, `Squirrel`, a `.wixburn`
section). They exist so framework detection — including the **ambiguous** case where two
signatures match and the result must be `FRAMEWORK_AMBIGUOUS` rather than a guess — can be
tested without downloading a single vendor installer.

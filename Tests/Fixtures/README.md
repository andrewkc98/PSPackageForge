# Test fixtures — provenance

Everything in this directory is **built by us from source that is committed alongside it**.
No third-party installer binary is ever committed to this repository (see the repository
README, Opsec section). CI enforces that rule.

These fixtures are committed rather than generated at test time on purpose. Building MSIs
during a test run via `OpenDatabase` mode 3 and `.idt` imports is a day of pain, produces
non-deterministic output, and reviewers do not care. Two tiny MSIs built once with the WiX
toolset give the suite a deterministic spine that runs identically on a laptop and on
`windows-latest`.

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

*Not yet built — build order step 9.*

An MSI shaped like Mozilla's Firefox ESR package: a `ProductCode` present in the `Property`
table, an executable in the `Binary` table, a custom action that launches it, and **no
meaningful installable `File`/`Component` payload**. It exists to prove that PSPackageForge
sets `MsiKind = Wrapper` and `SupportsMsiUninstall = $false` even though `ProductCodePresent`
is `$true`, and that it never attempts `msiexec /x` against it.

## `framework-stubs/`

*Not yet built — build order step 11.*

Small synthetic PE files carrying the identification signatures of each supported installer
framework (`NullsoftInst`, `Inno Setup Setup Data`, `InstallShield`, `Squirrel`, a `.wixburn`
section). They exist so framework detection — including the **ambiguous** case where two
signatures match and the result must be `FRAMEWORK_AMBIGUOUS` rather than a guess — can be
tested without downloading a single vendor installer.

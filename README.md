PSPackageForge

CI PowerShell 5.1 | 7

Point it at an .exe or .msi and get back the silent install command, the uninstall command, and a working detection script for MECM or Intune. Every value is traced to where it came from, and anything the tool could not prove is flagged for review instead of guessed.

It is for the sysadmin who packages applications and is tired of researching the same four questions from scratch for every new installer.

The problem

Before an application can be deployed through MECM or Intune, someone has to work out how to install it silently, how to uninstall it, where it lands on disk, and how the management agent can tell it is there. For an MSI most of that is inside the file. For an EXE it is not. You identify the installer framework, search for its silent switches, install it on a test machine, and dig through the registry for the real uninstall string.

The research is tedious, but the expensive part is getting it slightly wrong, because the failures are quiet. An install can succeed and still be reported as failed because detection looked in the wrong place (0x87D00324). An uninstall command can sit untested for a year and then fail with 1619 the day someone needs it.

KiCad is the application that pushed me to build this. It ships as an NSIS installer, registers no MSI product code, and installs into a versioned folder. Any package that assumes MSI-style uninstall and detection is wrong on both counts, and nothing tells you until a client reports it.

How it works

There are three steps, and the tool stops between them on purpose.

Discover is optional and runs on a reference machine where the application is already installed. It reads the uninstall registry (32-bit, 64-bit, and per-user views) and exports what it finds as JSON. This is how the tool learns things an installer file cannot reveal offline, such as the real uninstall command and install location.

Scaffold analyses the installer itself. For an MSI it reads the Windows Installer database directly. For an EXE it reads the PE header and looks for framework signatures (NSIS, Inno Setup, Squirrel, WiX Burn, InstallShield). Each source produces evidence, the evidence is merged by a fixed order of trust, and the result is resolved into a package specification.

Pack is optional and turns the reviewed scaffold into a PSAppDeployToolkit package and an .intunewin file.

text
MSI database   ─┐
PE metadata    ─┤
Registry / JSON ─┼─▶  merge evidence  ─▶  installer facts  ─▶  package decisions  ─▶  outputs
Known quirks   ─┘

What comes out is a folder containing a machine-readable manifest, a detection script, and a review document written for a human. The review document lists the commands, the detection method, the install context, a table showing which source produced each value and how confident it is, and a checklist of what to verify before deploying. For KiCad, the summary looks like this:

text
Install command    : KiCad-Setup.exe /S /allusers
Uninstall command  : "C:\Program Files\KiCad\10.0\Uninstall.exe" /S
Detection          : File version of C:\Program Files\KiCad\*\bin\kicad.exe
Install behaviour  : Install for system
Readiness          : ReviewRequired
Finding            : [Info] CONTEXT_FLAG_NOT_BEHAVIOR

That last finding records that /allusers is an installer argument, not an MECM setting, so "Install for system" still has to be set on the deployment type. This is the kind of detail that normally lives in one admin's head.

A full generated example is in Examples/SevenZip.

By the numbers
Five installer frameworks are identified by signature. Four receive known silent arguments. InstallShield is recognised and deliberately sent to review, because its switches vary too much to infer safely.
Four real applications serve as regression cases, each chosen because it breaks a different assumption: 7-Zip (plain MSI), Firefox ESR (an MSI that wraps an EXE), KiCad (NSIS with versioned paths), and Obsidian (per-user Squirrel install).
Roughly 300 Pester tests across 20 test files, plus PSScriptAnalyzer, run in CI on both Windows PowerShell 5.1 and PowerShell 7. A third CI job scans the full git history to confirm no vendor installers or employer details were ever committed.
<!-- TODO (Andrew): add a measured before/after here if you have one, e.g. "Packaging a new EXE went from about X minutes of research to about Y minutes of review." Leave this out entirely rather than estimate. -->
Tech stack

Pure PowerShell, with no compiled dependencies and no ConfigMgr console required. It runs on Windows PowerShell 5.1, which is still what most MECM environments have, and on PowerShell 7. MSI files are read through the Windows Installer COM interface, and EXE files are parsed at the byte level. Tests use Pester 5, linting uses PSScriptAnalyzer, and CI runs on GitHub Actions. PSAppDeployToolkit 4.0.6 and Microsoft's IntuneWinAppUtil.exe are needed only for the optional pack step, and the tool never downloads either one.

Why it is designed this way

The central decision is that the tool would rather stop than be confidently wrong. In packaging, a plausible wrong answer is worse than no answer, because it deploys cleanly and fails later on several hundred machines.

Three things follow from that. First, facts about the installer are kept separate from decisions about the deployment, so a piece of metadata never quietly becomes a setting. Second, confidence is tracked for each field, not for the package as a whole, since the product version might come straight from the MSI database while the detection target is an educated guess. When two trusted sources disagree, the conflict is recorded and the value is downgraded. Third, the best status a package can ever reach is ReviewRequired. An unknown EXE gets no install command at all, and a package with unresolved critical values cannot be packed.

The tool does the research and shows its work. A person still makes the call and tests the result.

Quick start

Requires Windows and PowerShell 5.1 or later.

powershell
git clone https://github.com/andrewkc98/PSPackageForge
Import-Module ./PSPackageForge/PSPackageForge.psd1

# 1. Optional: on a machine with the app installed, capture what the registry knows
psforge discover 'KiCad*' -Output C:\Installers\KiCad.discovery.json

# 2. Analyse the installer and generate the review bundle
psforge scaffold C:\Installers\KiCad-Setup.exe -Discovery C:\Installers\KiCad.discovery.json -Output C:\Installers\KiCad-Scaffold

# 3. Optional: after reviewing PackageDocument.md, build the .intunewin
psforge pack C:\Installers\KiCad-Scaffold

For an MSI, step 2 alone is usually enough: psforge scaffold C:\Installers\7z2602-x64.msi.

Open PackageDocument.md in the output folder, work through the checklist, and use the commands and Detect-Application.ps1 when creating the application in MECM or Intune.

More detail

The full reference covers evidence precedence, the detection script contract, the EXE signature table, the lower-level cmdlets, the roadmap, and what is out of scope. See docs/REFERENCE.md.

Licence

MIT. See LICENSE.

#Requires -Version 5.1

<#
    PSPackageForge -- MECM/Intune packaging scaffolder.

    This file defines the type contract and loads the module. It deliberately contains no
    business logic: providers live in Private/Providers, resolution in Private/Resolution,
    and rendering in Private/Rendering.

    The central design property (plan §2): the tool must never emit a confident wrong
    answer. Three rules follow, and they are why the types look the way they do.

      1. Facts and decisions are different things.  InstallerInfo answers "what is this
         file?".  PackageSpec answers "how should we deploy it?".  Nothing crosses over.
      2. Every resolved field knows where it came from.  EvidenceRecord is per-field, not
         per-package.
      3. Low confidence has operational consequences.  Readiness never reaches
         "ReadyToDeploy" -- the ceiling is ReviewRequired.
#>

Set-StrictMode -Version Latest


#region Enumerations

<#
    Where a discovered value came from.

    The integer values ARE the merge precedence from plan §5.3 -- higher wins. Encoding
    precedence in the enum rather than a lookup table means a new source cannot be added
    without consciously deciding where it ranks.

        UserOverride > DiscoveryJson > MsiDatabase > KnownQuirk > PeMetadata > Inferred

    Registry is not named in the plan's precedence list even though it is a valid source,
    because in v1 registry facts normally arrive via DiscoveryJson. It is ranked just
    below DiscoveryJson here: a live registry read is direct observation of an installed
    product, so it outranks static MSI metadata, but an exported discovery file is the
    reviewed artefact and wins on a tie. This choice is documented in README.md.

    Sandbox will slot in above Registry when plan §4.1 lands; it is empirical rather than
    inferred, but still machine-generated and unreviewed.
#>
enum EvidenceSource {
    Inferred     = 10
    PeMetadata   = 20
    KnownQuirk   = 30
    MsiDatabase  = 40
    Registry     = 45
    DiscoveryJson = 50
    UserOverride = 60
}

# Ordered so that Low -lt High works as written.
enum ConfidenceLevel {
    Low    = 1
    Medium = 2
    High   = 3
}

<#
    Blocking is not merely "worse than Warning". A Blocking finding on a critical decision
    forces Readiness to NeedsInput and suppresses runnable output entirely (plan §5.5).
#>
enum FindingSeverity {
    Info     = 1
    Warning  = 2
    Blocking = 3
}

# What the supplied file IS.
enum ContainerType {
    Unknown = 0
    Msi     = 1
    Exe     = 2
    Msix    = 3
}

<#
    What the container actually installs. Separate from ContainerType on purpose: Firefox
    ESR is the regression case, with ContainerType = Msi but PayloadType = Exe.
#>
enum PayloadType {
    Unknown = 0
    Msi     = 1
    Exe     = 2
    Mixed   = 3
}

<#
    Native  -- real payload, features, and product registration. msiexec /x works.
    Wrapper -- an MSI shell around a vendor EXE. A ProductCode may exist syntactically
               without producing the installed-product behaviour MECM expects, so
               SupportsMsiUninstall is $false regardless of ProductCodePresent.
#>
enum MsiKind {
    Unknown       = 0
    Native        = 1
    Wrapper       = 2
    NotApplicable = 3
}

enum InstallerFramework {
    Unknown        = 0
    MsiNative      = 1
    Nsis           = 2
    InnoSetup      = 3
    InstallShield  = 4
    Squirrel       = 5
    WiXBurn        = 6
}

<#
    Never inferred from the host PSPackageForge happens to be running on (plan §7.2).
    Neutral means genuinely architecture-independent, not "we could not tell" -- that is
    Unknown.
#>
enum ArchitectureType {
    Unknown = 0
    x86     = 1
    x64     = 2
    Arm64   = 3
    Neutral = 4
}

<#
    Explicit registry view. Generated detection scripts must never rely on whatever view
    they happen to inherit -- whether ConfigMgr runs a detection script 32-bit is a
    deployment-type option, not a default to architect around (plan §7.2).
#>
enum RegistryViewType {
    Default    = 0
    Registry32 = 1
    Registry64 = 2
}

enum InstallContext {
    Unknown = 0
    System  = 1
    User    = 2
}

<#
    There is deliberately no ReadyToDeploy member. The project is a scaffolder, not a
    package-certification engine; the ceiling is "ready for testing" (plan §2).
#>
enum ReadinessLevel {
    NeedsInput     = 1
    ReviewRequired = 2
}

# A choice, not a constant -- GreaterOrEqual is not universally correct (plan §7.3).
enum DetectionOperator {
    Exists         = 0
    Exact          = 1
    GreaterOrEqual = 2
}

enum DetectionKind {
    File     = 0
    Registry = 1
    MsiProductCode = 2
}

<#
    Return codes are modelled, not listed (plan §7.6). Note there is no member that maps
    1619 to success: 1619 is a package-open failure, and registering it as a success code
    is how a broken uninstall gets reported green across a fleet.
#>
enum ReturnCodeClass {
    Failure                = 0
    Success                = 1
    SuccessRebootRequired  = 2
    SuccessRebootInitiated = 3
    Retry                  = 4
}

enum RebootBehaviorType {
    Unknown             = 0
    NoAction            = 1
    ForceReboot         = 2
    SuppressReboot      = 3
    ProgramReboot       = 4
}

#endregion Enumerations


#region Core types

<#
    One discovered value, with its provenance. Providers emit these; they never construct
    a finished InstallerInfo (plan §5.3).
#>
class EvidenceRecord {
    [string]          $Field
    [object]          $Value
    [EvidenceSource]  $Source
    [ConfidenceLevel] $Confidence
    [string]          $Notes

    EvidenceRecord() { }

    EvidenceRecord([string] $field, [object] $value, [EvidenceSource] $source, [ConfidenceLevel] $confidence) {
        $this.Field      = $field
        $this.Value      = $value
        $this.Source     = $source
        $this.Confidence = $confidence
    }

    EvidenceRecord([string] $field, [object] $value, [EvidenceSource] $source, [ConfidenceLevel] $confidence, [string] $notes) {
        $this.Field      = $field
        $this.Value      = $value
        $this.Source     = $source
        $this.Confidence = $confidence
        $this.Notes      = $notes
    }

    # Merge precedence is the enum's numeric value; see the EvidenceSource comment.
    [int] Precedence() {
        return [int] $this.Source
    }

    <#
        The merger downgrades confidence when high-confidence sources disagree. It must do
        that to a copy: the record a provider emitted is the audit trail of what that
        provider actually observed, and rewriting it in place would destroy the evidence
        the downgrade is supposed to explain.
    #>
    [EvidenceRecord] Clone() {
        return [EvidenceRecord]::new($this.Field, $this.Value, $this.Source, $this.Confidence, $this.Notes)
    }

    [string] ToString() {
        return ('{0} = {1} [{2}/{3}]' -f $this.Field, $this.Value, $this.Source, $this.Confidence)
    }

    # Enums must render as strings, not integers, or the manifest would differ between
    # Windows PowerShell 5.1 and PowerShell 7. Serialisation shape is fixed here.
    [System.Collections.Specialized.OrderedDictionary] ToOrderedDictionary() {
        $d = [ordered] @{
            Field      = $this.Field
            Value      = $this.Value
            Source     = $this.Source.ToString()
            Confidence = $this.Confidence.ToString()
        }
        if (-not [string]::IsNullOrWhiteSpace($this.Notes)) { $d['Notes'] = $this.Notes }
        return $d
    }
}

<#
    Replaces the flat Warnings[] of earlier drafts. Code is a short stable identifier so
    tests and documentation can refer to a condition without matching on message text.
#>
class Finding {
    [FindingSeverity] $Severity
    [string]          $Code
    [string]          $Message
    [string]          $Field

    Finding() { }

    Finding([FindingSeverity] $severity, [string] $code, [string] $message) {
        $this.Severity = $severity
        $this.Code     = $code
        $this.Message  = $message
    }

    Finding([FindingSeverity] $severity, [string] $code, [string] $message, [string] $field) {
        $this.Severity = $severity
        $this.Code     = $code
        $this.Message  = $message
        $this.Field    = $field
    }

    [bool] IsBlocking() {
        return $this.Severity -eq [FindingSeverity]::Blocking
    }

    [string] ToString() {
        return ('[{0}] {1}: {2}' -f $this.Severity, $this.Code, $this.Message)
    }

    [System.Collections.Specialized.OrderedDictionary] ToOrderedDictionary() {
        $d = [ordered] @{
            Severity = $this.Severity.ToString()
            Code     = $this.Code
            Message  = $this.Message
        }
        if (-not [string]::IsNullOrWhiteSpace($this.Field)) { $d['Field'] = $this.Field }
        return $d
    }
}

<#
    Commands are structured, never strings (plan §5.2).

    Nothing inside the module may carry "C:\setup.exe /S /allusers". Rendering to a quoted
    string happens exactly once, at the output boundary, in ConvertTo-CommandString. This
    kills an entire class of quoting bug and lets the PSADT renderer, the doc renderer and
    any future MECM/Intune renderer format the same command their own way without
    reparsing it.
#>
class CommandSpec {
    [string]   $Executable
    [string[]] $ArgumentList
    [string]   $WorkingDirectory
    [int[]]    $ExpectedExitCodes

    CommandSpec() {
        $this.ArgumentList      = @()
        $this.ExpectedExitCodes = @(0)
    }

    CommandSpec([string] $executable, [string[]] $argumentList) {
        $this.Executable        = $executable
        $this.ArgumentList      = @($argumentList)
        $this.ExpectedExitCodes = @(0)
    }

    CommandSpec([string] $executable, [string[]] $argumentList, [int[]] $expectedExitCodes) {
        $this.Executable        = $executable
        $this.ArgumentList      = @($argumentList)
        $this.ExpectedExitCodes = @($expectedExitCodes)
    }

    [bool] IsResolved() {
        return -not [string]::IsNullOrWhiteSpace($this.Executable)
    }

    [System.Collections.Specialized.OrderedDictionary] ToOrderedDictionary() {
        $d = [ordered] @{
            Executable        = $this.Executable
            ArgumentList      = @($this.ArgumentList)
            ExpectedExitCodes = @($this.ExpectedExitCodes)
        }
        if (-not [string]::IsNullOrWhiteSpace($this.WorkingDirectory)) {
            $d['WorkingDirectory'] = $this.WorkingDirectory
        }
        return $d
    }
}

<#
    A detection rule with real values in it. Kind decides which fields matter:
      File           -- Path + FileName + Operator + Value (property Version)
      Registry       -- KeyPath + ValueName + RegistryView + Operator + Value
      MsiProductCode -- Value carries the ProductCode GUID
#>
class DetectionSpec {
    [DetectionKind]     $Kind
    [string]            $Path
    [string]            $FileName
    [string]            $KeyPath
    [string]            $ValueName
    [RegistryViewType]  $RegistryView
    [DetectionOperator] $Operator
    [string]            $Value
    [bool]              $UsesWildcardPath
    [ConfidenceLevel]   $Confidence
    [string]            $Rationale

    DetectionSpec() {
        $this.RegistryView = [RegistryViewType]::Default
        $this.Operator     = [DetectionOperator]::Exists
        $this.Confidence   = [ConfidenceLevel]::Low
    }

    [System.Collections.Specialized.OrderedDictionary] ToOrderedDictionary() {
        $d = [ordered] @{ Kind = $this.Kind.ToString() }

        switch ($this.Kind) {
            ([DetectionKind]::File) {
                $d['Path']             = $this.Path
                $d['FileName']         = $this.FileName
                $d['UsesWildcardPath'] = $this.UsesWildcardPath
            }
            ([DetectionKind]::Registry) {
                $d['KeyPath']      = $this.KeyPath
                $d['ValueName']    = $this.ValueName
                $d['RegistryView'] = $this.RegistryView.ToString()
            }
            ([DetectionKind]::MsiProductCode) { }
        }

        $d['Operator']   = $this.Operator.ToString()
        $d['Value']      = $this.Value
        $d['Confidence'] = $this.Confidence.ToString()
        if (-not [string]::IsNullOrWhiteSpace($this.Rationale)) { $d['Rationale'] = $this.Rationale }
        return $d
    }
}

class ReturnCodeMapping {
    [int]             $Code
    [string]          $Meaning
    [ReturnCodeClass] $Classification
    [string]          $Notes

    ReturnCodeMapping() { }

    ReturnCodeMapping([int] $code, [string] $meaning, [ReturnCodeClass] $classification) {
        $this.Code           = $code
        $this.Meaning        = $meaning
        $this.Classification = $classification
    }

    [System.Collections.Specialized.OrderedDictionary] ToOrderedDictionary() {
        $d = [ordered] @{
            Code           = $this.Code
            Meaning        = $this.Meaning
            Classification = $this.Classification.ToString()
        }
        if (-not [string]::IsNullOrWhiteSpace($this.Notes)) { $d['Notes'] = $this.Notes }
        return $d
    }
}

class SignatureInfo {
    [bool]   $IsSigned
    [string] $Status
    [string] $SignerSubject
    [string] $SignerThumbprint
    [string] $TimestampUtc

    SignatureInfo() {
        $this.IsSigned = $false
        $this.Status   = 'NotChecked'
    }

    [System.Collections.Specialized.OrderedDictionary] ToOrderedDictionary() {
        return [ordered] @{
            IsSigned         = $this.IsSigned
            Status           = $this.Status
            SignerSubject    = $this.SignerSubject
            SignerThumbprint = $this.SignerThumbprint
            TimestampUtc     = $this.TimestampUtc
        }
    }
}

<#
    Facts about the supplied file. No deployment decisions live here -- if a field would
    answer "how should we deploy it?", it belongs on PackageSpec instead.
#>
class InstallerInfo {
    # Identity
    [string]        $Path
    [string]        $FileName
    [string]        $SHA256
    [long]          $FileSize
    [SignatureInfo] $Signature

    # Classification
    [ContainerType]        $ContainerType
    [PayloadType]          $PayloadType
    [MsiKind]              $MsiKind
    [InstallerFramework]   $Framework
    [InstallerFramework[]] $FrameworkCandidates

    [ArchitectureType] $Architecture

    # Product metadata -- raw, never normalised here (plan §7.3)
    [string] $ProductName
    [string] $Manufacturer
    [string] $ProductVersionRaw
    [string] $ProductCode
    [string] $UpgradeCode
    [string] $Language

    [bool] $ProductCodePresent
    [bool] $SupportsMsiUninstall

    [EvidenceRecord[]] $Evidence
    [Finding[]]        $Findings

    InstallerInfo() {
        $this.Signature            = [SignatureInfo]::new()
        $this.ContainerType        = [ContainerType]::Unknown
        $this.PayloadType          = [PayloadType]::Unknown
        $this.MsiKind              = [MsiKind]::Unknown
        $this.Framework            = [InstallerFramework]::Unknown
        $this.FrameworkCandidates  = @()
        $this.Architecture         = [ArchitectureType]::Unknown
        $this.ProductCodePresent   = $false
        $this.SupportsMsiUninstall = $false
        $this.Evidence             = @()
        $this.Findings             = @()
    }

    # Per-field provenance lookup. This is rule 2 of plan §2 made queryable.
    [EvidenceRecord] GetEvidence([string] $field) {
        foreach ($record in $this.Evidence) {
            if ($record.Field -eq $field) { return $record }
        }
        return $null
    }

    [System.Collections.Specialized.OrderedDictionary] ToOrderedDictionary() {
        return [ordered] @{
            Path                 = $this.Path
            FileName             = $this.FileName
            SHA256               = $this.SHA256
            FileSize             = $this.FileSize
            Signature            = $this.Signature.ToOrderedDictionary()
            ContainerType        = $this.ContainerType.ToString()
            PayloadType          = $this.PayloadType.ToString()
            MsiKind              = $this.MsiKind.ToString()
            Framework            = $this.Framework.ToString()
            FrameworkCandidates  = @($this.FrameworkCandidates | ForEach-Object { $_.ToString() })
            Architecture         = $this.Architecture.ToString()
            ProductName          = $this.ProductName
            Manufacturer         = $this.Manufacturer
            ProductVersionRaw    = $this.ProductVersionRaw
            ProductCode          = $this.ProductCode
            UpgradeCode          = $this.UpgradeCode
            Language             = $this.Language
            ProductCodePresent   = $this.ProductCodePresent
            SupportsMsiUninstall = $this.SupportsMsiUninstall
            Evidence             = @($this.Evidence | ForEach-Object { $_.ToOrderedDictionary() })
            Findings             = @($this.Findings | ForEach-Object { $_.ToOrderedDictionary() })
        }
    }
}

<#
    Deployment decisions, resolved from evidence. Readiness is computed, never assigned by
    a caller -- see RecalculateReadiness.
#>
class PackageSpec {
    [CommandSpec] $InstallCommand
    [CommandSpec] $UninstallCommand

    [InstallContext[]]  $SupportedContexts
    [InstallContext]    $SelectedContext
    [EvidenceRecord[]]  $ContextEvidence
    [bool]              $RequiresLogonWhenUserContext

    [DetectionSpec[]]     $DetectionSpec
    [ReturnCodeMapping[]] $ReturnCodeMap
    [RebootBehaviorType]  $RebootBehavior
    [int]                 $PostInstallDelaySeconds
    [bool]                $RunDetectionAs32Bit

    [ReadinessLevel] $Readiness
    [Finding[]]      $BlockingFindings

    [string] $SchemaVersion
    [string] $GeneratorVersion

    PackageSpec() {
        $this.InstallCommand               = [CommandSpec]::new()
        $this.UninstallCommand             = [CommandSpec]::new()
        $this.SupportedContexts            = @()
        $this.SelectedContext              = [InstallContext]::Unknown
        $this.ContextEvidence              = @()
        $this.RequiresLogonWhenUserContext = $false
        $this.DetectionSpec                = @()
        $this.ReturnCodeMap                = @()
        $this.RebootBehavior               = [RebootBehaviorType]::Unknown
        $this.PostInstallDelaySeconds      = 0
        $this.RunDetectionAs32Bit          = $false
        $this.Readiness                    = [ReadinessLevel]::NeedsInput
        $this.BlockingFindings             = @()
    }

    <#
        The four critical decisions of plan §5.5. If any is unresolved the scaffold still
        emits a manifest and a document, but must not emit a runnable deployment that
        silently picked a candidate.
    #>
    [bool] HasResolvedCriticalDecisions() {
        if (-not $this.InstallCommand.IsResolved())   { return $false }
        if (-not $this.UninstallCommand.IsResolved()) { return $false }
        if ($this.SelectedContext -eq [InstallContext]::Unknown) { return $false }
        if ($this.DetectionSpec.Count -eq 0)          { return $false }
        return $true
    }

    # ReviewRequired is the ceiling, and only when nothing is blocking.
    [ReadinessLevel] RecalculateReadiness() {
        if ($this.BlockingFindings.Count -gt 0 -or -not $this.HasResolvedCriticalDecisions()) {
            $this.Readiness = [ReadinessLevel]::NeedsInput
        }
        else {
            $this.Readiness = [ReadinessLevel]::ReviewRequired
        }
        return $this.Readiness
    }

    [System.Collections.Specialized.OrderedDictionary] ToOrderedDictionary() {
        return [ordered] @{
            InstallCommand               = $this.InstallCommand.ToOrderedDictionary()
            UninstallCommand             = $this.UninstallCommand.ToOrderedDictionary()
            SupportedContexts            = @($this.SupportedContexts | ForEach-Object { $_.ToString() })
            SelectedContext              = $this.SelectedContext.ToString()
            ContextEvidence              = @($this.ContextEvidence | ForEach-Object { $_.ToOrderedDictionary() })
            RequiresLogonWhenUserContext = $this.RequiresLogonWhenUserContext
            DetectionSpec                = @($this.DetectionSpec | ForEach-Object { $_.ToOrderedDictionary() })
            ReturnCodeMap                = @($this.ReturnCodeMap | ForEach-Object { $_.ToOrderedDictionary() })
            RebootBehavior               = $this.RebootBehavior.ToString()
            PostInstallDelaySeconds      = $this.PostInstallDelaySeconds
            RunDetectionAs32Bit          = $this.RunDetectionAs32Bit
            Readiness                    = $this.Readiness.ToString()
            BlockingFindings             = @($this.BlockingFindings | ForEach-Object { $_.ToOrderedDictionary() })
            SchemaVersion                = $this.SchemaVersion
            GeneratorVersion             = $this.GeneratorVersion
        }
    }
}

#endregion Core types


#region Module load

$script:ModuleRoot = $PSScriptRoot

# Pinned contract and toolchain versions, read from the manifest so there is exactly one
# place to change them.
$script:ForgeManifestData        = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot 'PSPackageForge.psd1')
$script:GeneratorVersion         = $script:ForgeManifestData.ModuleVersion
$script:ManifestSchemaVersion    = $script:ForgeManifestData.PrivateData.PSPackageForge.ManifestSchemaVersion
$script:DiscoverySchemaVersion   = $script:ForgeManifestData.PrivateData.PSPackageForge.DiscoverySchemaVersion
$script:RequiredPSADTVersion     = $script:ForgeManifestData.PrivateData.PSPackageForge.RequiredPSADTVersion

$script:ConfigRoot    = Join-Path $PSScriptRoot 'Config'
$script:TemplateRoot  = Join-Path $PSScriptRoot 'Templates'

<#
    A constraint worth knowing before adding a public function.

    Classes defined here are visible to everything dot-sourced below, and to anything
    running in module scope -- which includes every Private function and any Pester test
    using InModuleScope. They are NOT visible to a caller who ran a plain Import-Module,
    because Windows PowerShell 5.1 only exports module classes via `using module`.

    Parameter types and [OutputType()] on an EXPORTED function are resolved in the caller's
    type context. So a public function must NOT declare a module class in its signature:

        BAD   [OutputType([InstallerInfo])]  param([EvidenceRecord[]] $Evidence)
        GOOD  [OutputType('InstallerInfo')]  param([object[]] $Evidence)   # validated inside

    Private functions are called only from module scope and use the class types directly.
#>

# Private first: public functions depend on them, never the reverse.
foreach ($scope in @('Private', 'Public')) {
    $scopeRoot = Join-Path $PSScriptRoot $scope
    if (-not (Test-Path -LiteralPath $scopeRoot)) { continue }

    $files = Get-ChildItem -Path $scopeRoot -Filter '*.ps1' -Recurse -File |
        Sort-Object -Property FullName

    foreach ($file in $files) {
        try {
            . $file.FullName
        }
        catch {
            throw ('PSPackageForge: failed to load {0}: {1}' -f $file.FullName, $_.Exception.Message)
        }
    }
}

Export-ModuleMember -Function $script:ForgeManifestData.FunctionsToExport

#endregion Module load

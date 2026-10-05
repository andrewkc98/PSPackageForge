[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ObsidianPath,
    [Parameter(Mandatory)][string] $KiCadPath,
    [Parameter(Mandatory)][string] $BaselinePath,
    [Parameter(Mandatory)][string] $OutputPath,
    [ValidateRange(10, 600)][int] $TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$modulePath = Join-Path $repoRoot 'PSPackageForge.psd1'
$metadataPath = Join-Path $repoRoot 'Private/Providers/Read-PortableExecutableMetadata.ps1'
$evidencePath = Join-Path $repoRoot 'Private/Providers/Get-ExeEvidence.ps1'
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { throw "Output path already exists; choose a unique retained path: $OutputPath" }
[void](New-Item -ItemType Directory -Path $OutputPath -ErrorAction Stop)

foreach ($path in @($ObsidianPath, $KiCadPath, $BaselinePath, $modulePath, $metadataPath, $evidencePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required input is missing: $path" }
}

$markers = @('NullsoftInst', 'Inno Setup Setup Data', 'InstallShield Setup Launcher', 'SquirrelSetup', 'SquirrelAwareVersion', 'Installer for Squirrel-based applications')
$sourceText = Get-Content -LiteralPath $evidencePath -Raw
foreach ($marker in $markers) {
    if (-not $sourceText.Contains("'$marker'")) { throw "Expected production marker is absent from Get-ExeEvidence.ps1: $marker" }
}
Import-Module -Name $modulePath -Force -ErrorAction Stop

function Invoke-ModuleReader {
    param([string] $Path, [string[]] $AsciiMarkers = @(), [string[]] $Utf16LEMarkers = @())
    $module = Get-Module -Name PSPackageForge | Select-Object -First 1
    & $module {
        param($ReaderPath, $Ascii, $Utf16)
        Read-PortableExecutableData -Path $ReaderPath -AsciiMarkers $Ascii -Utf16LEMarkers $Utf16 -ChunkSize 4096
    } $Path $AsciiMarkers $Utf16LEMarkers
}

function New-SyntheticPe {
    param([string] $Path, [int] $Bytes, [string[]] $Payload = @(), [int] $PayloadOffset = 512, [ValidateSet('ASCII','UTF16LE')][string] $PayloadEncoding = 'ASCII')
    $data = New-Object byte[] $Bytes
    $data[0] = 0x4D; $data[1] = 0x5A
    [Array]::Copy([BitConverter]::GetBytes([int]128), 0, $data, 60, 4)
    $data[128] = 0x50; $data[129] = 0x45
    [Array]::Copy([BitConverter]::GetBytes([UInt16]0x8664), 0, $data, 132, 2)
    [Array]::Copy([BitConverter]::GetBytes([UInt16]1), 0, $data, 134, 2)
    [Array]::Copy([BitConverter]::GetBytes([UInt16]240), 0, $data, 148, 2)
    [Array]::Copy([BitConverter]::GetBytes([UInt16]0x20B), 0, $data, 152, 2)
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('.text'), 0, $data, 392, 5)
    [Array]::Copy([BitConverter]::GetBytes([UInt32]($Bytes - 512)), 0, $data, 408, 4)
    [Array]::Copy([BitConverter]::GetBytes([UInt32]512), 0, $data, 412, 4)
    if ($Payload.Count -gt 0) {
        $encoding = if ($PayloadEncoding -eq 'UTF16LE') { [Text.Encoding]::Unicode } else { [Text.Encoding]::ASCII }
        $payloadBytes = $encoding.GetBytes(($Payload -join '|'))
        if ($PayloadOffset -lt 512 -or ($PayloadOffset + $payloadBytes.Length) -gt $Bytes) { throw 'Synthetic payload is outside its PE section bounds.' }
        [Array]::Copy($payloadBytes, 0, $data, $PayloadOffset, $payloadBytes.Length)
    }
    [IO.File]::WriteAllBytes($Path, $data)
}

function Find-ReferenceMarker {
    param([byte[]] $Haystack, [byte[]] $Needle)
    if ($Needle.Length -eq 0 -or $Needle.Length -gt $Haystack.Length) { return $false }
    for ($i = 0; $i -le $Haystack.Length - $Needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) { $match = $false; break }
        }
        if ($match) { return $true }
    }
    return $false
}

function Invoke-ReferenceMarkerScan {
    param([string] $Path, [string[]] $AsciiMarkers, [string[]] $Utf16LEMarkers)
    $ascii = @($AsciiMarkers | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique)
    $utf16 = @($Utf16LEMarkers | Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique)
    $asciiBytes = @($ascii | ForEach-Object { ,([Text.Encoding]::ASCII.GetBytes($_)) })
    $utf16Bytes = @($utf16 | ForEach-Object { ,([Text.Encoding]::Unicode.GetBytes($_)) })
    $max = 0
    foreach ($pattern in @($asciiBytes + $utf16Bytes)) { if ($pattern.Length -gt $max) { $max = $pattern.Length } }
    $overlap = [Math]::Max(0, $max - 1)
    $foundAscii = [System.Collections.Generic.List[string]]::new()
    $foundUtf16 = [System.Collections.Generic.List[string]]::new()
    $stream = [IO.File]::OpenRead($Path)
    try {
        $carry = New-Object byte[] 0; $buffer = New-Object byte[] 4096
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $combined = New-Object byte[] ($carry.Length + $read)
            if ($carry.Length) { [Array]::Copy($carry, $combined, $carry.Length) }
            [Array]::Copy($buffer, 0, $combined, $carry.Length, $read)
            for ($index = 0; $index -lt $ascii.Count; $index++) {
                if ($foundAscii -notcontains $ascii[$index] -and (Find-ReferenceMarker -Haystack $combined -Needle $asciiBytes[$index])) { $foundAscii.Add($ascii[$index]) }
            }
            for ($index = 0; $index -lt $utf16.Count; $index++) {
                if ($foundUtf16 -notcontains $utf16[$index] -and (Find-ReferenceMarker -Haystack $combined -Needle $utf16Bytes[$index])) { $foundUtf16.Add($utf16[$index]) }
            }
            $keep = [Math]::Min($overlap, $combined.Length)
            $carry = if ($keep) { $combined[($combined.Length - $keep)..($combined.Length - 1)] } else { New-Object byte[] 0 }
        }
    }
    finally { $stream.Dispose() }
    [pscustomobject]@{ Ascii = $foundAscii.ToArray(); Utf16LE = $foundUtf16.ToArray() }
}

function Invoke-BoundedJob {
    param([scriptblock] $Action, [object[]] $ArgumentList = @(), [int] $LimitSeconds, [string] $Name)
    $worker = {
        param($Module, $Operation, $OperationArguments)
        Import-Module -Name $Module -Force -ErrorAction Stop
        $operationBlock = [scriptblock]::Create([string]$Operation)
        & $operationBlock @OperationArguments
    }
    $jobArguments = @($modulePath, $Action, ,$ArgumentList)
    $job = Start-Job -Name $Name -ScriptBlock $worker -ArgumentList $jobArguments
    if (-not (Wait-Job -Job $job -Timeout $LimitSeconds)) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        return [pscustomobject]@{ State = 'TimedOut'; Seconds = $LimitSeconds; Result = $null; Error = $null }
    }
    $state = [string]$job.State
    $errorText = $null
    $result = $null
    try { $result = Receive-Job -Job $job -ErrorAction Stop } catch { $errorText = $_.Exception.Message }
    return [pscustomobject]@{ State = $state; Seconds = $LimitSeconds; Result = $result; Error = $errorText }
}

$freshFixturePath = Join-Path (Join-Path $repoRoot 'Tests/Fixtures/framework-stubs') 'nsis.exe'
$freshImport = Invoke-BoundedJob -Name 'FreshProcessNsisMatcher' -LimitSeconds $TimeoutSeconds -Action {
    param($FixturePath)
    $before = $null -ne ('PSPackageForge.Internal.PortableMarkerMatcher' -as [type])
    $module = Get-Module -Name PSPackageForge | Select-Object -First 1
    $metadata = & $module { param($ReaderPath) Read-PortableExecutableData -Path $ReaderPath -AsciiMarkers @('NullsoftInst') -ChunkSize 4096 } $FixturePath
    $after = $null -ne ('PSPackageForge.Internal.PortableMarkerMatcher' -as [type])
    [pscustomobject]@{ TypeExistedBeforeFirstRead = $before; TypeExistsAfterFirstRead = $after; AsciiMarkersFound = @($metadata.AsciiMarkersFound) }
} -ArgumentList @($freshFixturePath)
if ($freshImport.State -ne 'Completed' -or $null -eq $freshImport.Result -or $freshImport.Result.TypeExistedBeforeFirstRead -or -not $freshImport.Result.TypeExistsAfterFirstRead -or @($freshImport.Result.AsciiMarkersFound) -notcontains 'NullsoftInst') {
    throw 'Fresh-process matcher compilation smoke failed on the NSIS framework fixture.'
}

$oneMiB = Join-Path $OutputPath 'markerless-1MiB.exe'
$eightMiB = Join-Path $OutputPath 'markerless-8MiB.exe'
$early = Join-Path $OutputPath 'positive-early.exe'
$late = Join-Path $OutputPath 'positive-late.exe'
New-SyntheticPe -Path $oneMiB -Bytes 1048576
New-SyntheticPe -Path $eightMiB -Bytes 8388608
New-SyntheticPe -Path $early -Bytes 1048576 -Payload $markers
New-SyntheticPe -Path $late -Bytes 1048576
$lateBytes = [IO.File]::ReadAllBytes($late)
$latePayload = [Text.Encoding]::Unicode.GetBytes(($markers -join '|'))
[Array]::Copy($latePayload, 0, $lateBytes, ($lateBytes.Length - $latePayload.Length), $latePayload.Length)
[IO.File]::WriteAllBytes($late, $lateBytes)
$boundaryAscii = Join-Path $OutputPath 'boundary-ascii-duplicates.exe'
$boundaryUtf16 = Join-Path $OutputPath 'boundary-utf16.exe'
$boundaryCase = Join-Path $OutputPath 'boundary-case-sensitive.exe'
New-SyntheticPe -Path $boundaryAscii -Bytes 16384 -Payload @('SquirrelSetup','NullsoftInst') -PayloadOffset 4094
New-SyntheticPe -Path $boundaryUtf16 -Bytes 16384 -Payload @('Inno Setup Setup Data') -PayloadOffset 4094 -PayloadEncoding UTF16LE
New-SyntheticPe -Path $boundaryCase -Bytes 16384 -Payload @('nullsoftinst') -PayloadOffset 4094

$timings = [ordered]@{}
$sw = [Diagnostics.Stopwatch]::StartNew()
$cold = Invoke-ModuleReader -Path $oneMiB -AsciiMarkers $markers -Utf16LEMarkers $markers
$sw.Stop(); $timings.ColdCompileAndFirst1MiB = $sw.ElapsedMilliseconds
$sw.Restart(); $warmOne = Invoke-ModuleReader -Path $oneMiB -AsciiMarkers $markers -Utf16LEMarkers $markers
$sw.Stop(); $timings.WarmMarkerless1MiB = $sw.ElapsedMilliseconds
$sw.Restart(); $warmEight = Invoke-ModuleReader -Path $eightMiB -AsciiMarkers $markers -Utf16LEMarkers $markers
$sw.Stop(); $timings.WarmMarkerless8MiB = $sw.ElapsedMilliseconds
$sw.Restart(); $earlyResult = Invoke-ModuleReader -Path $early -AsciiMarkers $markers -Utf16LEMarkers $markers
$sw.Stop(); $timings.WarmPositiveEarly1MiB = $sw.ElapsedMilliseconds
$sw.Restart(); $lateResult = Invoke-ModuleReader -Path $late -AsciiMarkers $markers -Utf16LEMarkers $markers
$sw.Stop(); $timings.WarmPositiveLate1MiB = $sw.ElapsedMilliseconds

$parityCases = [System.Collections.Generic.List[object]]::new()
$fixedFixtures = @('nsis.exe','inno-setup.exe','installshield.exe','squirrel.exe','wix-burn.exe','ambiguous.exe','unknown.exe') |
    ForEach-Object { Join-Path (Join-Path $repoRoot 'Tests/Fixtures/framework-stubs') $_ }
$parityInputs = foreach ($fixture in $fixedFixtures) { [pscustomobject]@{ Path = $fixture; Ascii = $markers; Utf16LE = $markers } }
$parityInputs += @(
    [pscustomobject]@{ Path = $boundaryAscii; Ascii = @('SquirrelSetup','NullsoftInst','SquirrelSetup'); Utf16LE = @() },
    [pscustomobject]@{ Path = $boundaryUtf16; Ascii = @(); Utf16LE = @('Inno Setup Setup Data','Inno Setup Setup Data') },
    [pscustomobject]@{ Path = $boundaryCase; Ascii = @('NullsoftInst'); Utf16LE = @() }
)
foreach ($case in $parityInputs) {
    $old = Invoke-ReferenceMarkerScan -Path $case.Path -AsciiMarkers $case.Ascii -Utf16LEMarkers $case.Utf16LE
    $new = Invoke-ModuleReader -Path $case.Path -AsciiMarkers $case.Ascii -Utf16LEMarkers $case.Utf16LE
    $same = (($old.Ascii -join "`0") -ceq ($new.AsciiMarkersFound -join "`0")) -and (($old.Utf16LE -join "`0") -ceq ($new.Utf16LEMarkersFound -join "`0"))
    $parityCases.Add([pscustomobject]@{ Name = [IO.Path]::GetFileName($case.Path); SameAsLegacyLoop = $same; LegacyAscii = @($old.Ascii); OptimizedAscii = @($new.AsciiMarkersFound); LegacyUtf16LE = @($old.Utf16LE); OptimizedUtf16LE = @($new.Utf16LEMarkersFound) })
    if (-not $same) { throw "Marker output parity failed for $($case.Path)." }
}

$inputs = @(
    [pscustomobject]@{ Name = 'Obsidian'; Path = [IO.Path]::GetFullPath($ObsidianPath); ExpectedBytes = 331012528; ExpectedSHA256 = 'F233DC24896B3F2D5F9E4B01111181A561D0760B2105F0A474024C5F3143A9BC' },
    [pscustomobject]@{ Name = 'KiCad'; Path = [IO.Path]::GetFullPath($KiCadPath); ExpectedBytes = 967765696; ExpectedSHA256 = '9E24DC47119F7C472128C2F293C5E3F35569274A44C905E60A7514D47C16CE48' }
)
$realResults = foreach ($input in $inputs) {
    $item = Get-Item -LiteralPath $input.Path
    $hash = (Get-FileHash -LiteralPath $input.Path -Algorithm SHA256).Hash
    if ($item.Length -ne $input.ExpectedBytes -or $hash -ne $input.ExpectedSHA256) { throw "Input identity mismatch for $($input.Name)." }
    $scan = Invoke-BoundedJob -Name "ExeScan-$($input.Name)" -LimitSeconds $TimeoutSeconds -Action {
        param($InputData)
        $Path = $InputData.Path; $Markers = $InputData.Markers
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $module = Get-Module -Name PSPackageForge | Select-Object -First 1
        $metadata = & $module { param($ReaderPath, $MarkerSet) Read-PortableExecutableData -Path $ReaderPath -AsciiMarkers $MarkerSet -Utf16LEMarkers $MarkerSet -ChunkSize 4096 } $Path $Markers
        $watch.Stop()
        [pscustomobject]@{ ElapsedMilliseconds = $watch.ElapsedMilliseconds; AsciiMarkersFound = @($metadata.AsciiMarkersFound); Utf16LEMarkersFound = @($metadata.Utf16LEMarkersFound); Architecture = $metadata.Architecture; SectionNames = @($metadata.SectionNames); Version = $metadata.FileVersionInfo }
    } -ArgumentList @([pscustomobject]@{ Path = $input.Path; Markers = $markers })
    $endToEnd = Invoke-BoundedJob -Name "GetInstallerInfo-$($input.Name)" -LimitSeconds $TimeoutSeconds -Action {
        param($Path)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $info = Get-InstallerInfo -Path $Path
        $watch.Stop()
        [pscustomobject]@{ ElapsedMilliseconds = $watch.ElapsedMilliseconds; SHA256 = $info.SHA256; ContainerType = [string]$info.ContainerType; Framework = [string]$info.Framework; Signature = $info.Signature.Status; Evidence = @($info.Evidence | ForEach-Object { [pscustomobject]@{ Field = $_.Field; Value = [string]$_.Value; Source = [string]$_.Source; Confidence = [string]$_.Confidence } }) }
    } -ArgumentList @($input.Path)
    $hashWatch = [Diagnostics.Stopwatch]::StartNew(); [void](Get-FileHash -LiteralPath $input.Path -Algorithm SHA256); $hashWatch.Stop()
    $auth = Invoke-BoundedJob -Name "Authenticode-$($input.Name)" -LimitSeconds $TimeoutSeconds -Action {
        param($Path)
        $watch = [Diagnostics.Stopwatch]::StartNew(); $signature = Get-AuthenticodeSignature -LiteralPath $Path; $watch.Stop()
        [pscustomobject]@{ ElapsedMilliseconds = $watch.ElapsedMilliseconds; Status = [string]$signature.Status; Signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null } }
    } -ArgumentList @($input.Path)
    $pe = Invoke-BoundedJob -Name "PEMetadata-$($input.Name)" -LimitSeconds $TimeoutSeconds -Action {
        param($Path)
        $module = Get-Module -Name PSPackageForge | Select-Object -First 1
        $watch = [Diagnostics.Stopwatch]::StartNew(); $metadata = & $module { param($ReaderPath) Read-PortableExecutableData -Path $ReaderPath -ChunkSize 4096 } $Path; $watch.Stop()
        [pscustomobject]@{ ElapsedMilliseconds = $watch.ElapsedMilliseconds; Architecture = $metadata.Architecture; SectionNames = @($metadata.SectionNames); Version = $metadata.FileVersionInfo }
    } -ArgumentList @($input.Path)
    [pscustomobject]@{ Name = $input.Name; Path = $input.Path; Bytes = $item.Length; SHA256 = $hash; FullMarkerScan = $scan; GetInstallerInfo = $endToEnd; HashingMilliseconds = $hashWatch.ElapsedMilliseconds; Authenticode = $auth; PEHeaderAndVersionResource = $pe }
}

$cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Name
$baselineHash = (Get-FileHash -LiteralPath $BaselinePath -Algorithm SHA256).Hash
if ($baselineHash -ne '32B3064962C91FF3011055EB90DAD8E524F025B1B1D88468580B4E586B2A90E5') { throw 'The preserved baseline file hash did not match the approved input identity.' }
$sourcePaths = @($metadataPath, $evidencePath, (Join-Path $repoRoot 'Public/New-PackageScaffold.ps1'), $modulePath,
    (Join-Path $repoRoot 'PSPackageForge.psm1'), $PSCommandPath)
$sourcePaths += @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Private') -File -Recurse -Include *.ps1,*.psm1,*.psd1 | ForEach-Object { $_.FullName })
$sourcePaths += @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Public') -File -Recurse -Include *.ps1,*.psm1,*.psd1 | ForEach-Object { $_.FullName })
$sourceHashes = @($sourcePaths | Sort-Object -Unique | ForEach-Object {
    [pscustomobject]@{ Path = $_.Substring($repoRoot.Length).TrimStart('\', '/'); SHA256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})
$report = [ordered]@{
    GeneratedUtc = [DateTime]::UtcNow.ToString('o'); OS = [Environment]::OSVersion.VersionString
    PowerShell = $PSVersionTable.PSVersion.ToString(); PSEdition = $PSVersionTable.PSEdition
    DotNet = [Environment]::Version.ToString(); Processor = $cpu; ProcessorCount = [Environment]::ProcessorCount
    ChunkBytes = 4096; ProductionMarkers = $markers; PatternCount = ($markers.Count * 2)
    BaselineSourceSHA256 = 'DFD9DB28D7FC5EDD0628E62EB807F1F1526398714F044D0ED744A87E5A4CA19A'
    BaselineManifestSHA256 = '449131352F792109A472910EFFD2020D1FD4EB322679B708254A479CC2E2935A'
    BaselineObservedTimings = [ordered]@{ WarmMarkerless1MiBMilliseconds = 2167; WarmMarkerless8MiBMilliseconds = 15895; ObsidianFullScanMilliseconds = 120015; ObsidianScanResult = 'right-censored; no result returned' }
    SourceHashes = $sourceHashes; BaselinePath = $BaselinePath; BaselineSHA256 = $baselineHash
    FreshProcessCompilation = $freshImport
    Synthetic = [ordered]@{ Markerless1MiB = [pscustomobject]@{ Milliseconds = $timings.WarmMarkerless1MiB; Found = @($warmOne.AsciiMarkersFound) + @($warmOne.Utf16LEMarkersFound) }; Markerless8MiB = [pscustomobject]@{ Milliseconds = $timings.WarmMarkerless8MiB; Found = @($warmEight.AsciiMarkersFound) + @($warmEight.Utf16LEMarkersFound) }; PositiveEarly = [pscustomobject]@{ Milliseconds = $timings.WarmPositiveEarly1MiB; Ascii = @($earlyResult.AsciiMarkersFound); Utf16LE = @($earlyResult.Utf16LEMarkersFound) }; PositiveLate = [pscustomobject]@{ Milliseconds = $timings.WarmPositiveLate1MiB; Ascii = @($lateResult.AsciiMarkersFound); Utf16LE = @($lateResult.Utf16LEMarkersFound) }; BoundaryAndLegacyParity = $parityCases.ToArray(); ColdCompileAndFirst1MiBMilliseconds = $timings.ColdCompileAndFirst1MiB }
    RealInputs = @($realResults); TimeoutSeconds = $TimeoutSeconds
}
$jsonPath = Join-Path $OutputPath 'exe-scan-benchmark.json'
[IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 12
Write-Output "REPORT_PATH=$jsonPath"

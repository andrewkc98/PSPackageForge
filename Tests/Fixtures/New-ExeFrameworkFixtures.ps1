[CmdletBinding()]
param([string] $OutputDirectory = (Join-Path $PSScriptRoot 'framework-stubs'))
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
function __fUInt16 { param([byte[]]$Bytes,[int]$Offset,[int]$Value); $Bytes[$Offset]=[byte]($Value -band 0xff); $Bytes[$Offset+1]=[byte](($Value -shr 8)-band 0xff) }
function __fUInt32 { param([byte[]]$Bytes,[int]$Offset,[long]$Value); for($i=0;$i -lt 4;$i++){ $Bytes[$Offset+$i]=[byte](($Value -shr (8*$i))-band 0xff) } }
function __fAscii { param([byte[]]$Bytes,[int]$Offset,[string]$Value); $encoded=[Text.Encoding]::ASCII.GetBytes($Value); [Array]::Copy($encoded,0,$Bytes,$Offset,$encoded.Length) }
function __fPayload {
    param([object[]]$Parts)
    $payload = New-Object byte[] 0x1000
    foreach ($part in $Parts) {
        $isUnicode = ($part -is [Collections.IDictionary]) -and $part.Contains("Encoding") -and ([string]$part["Encoding"] -eq "Unicode")
        $encoding = if ($isUnicode) { [Text.Encoding]::Unicode } else { [Text.Encoding]::ASCII }
        $encoded = $encoding.GetBytes([string]$part.Text)
        [Array]::Copy($encoded, 0, $payload, [int]$part.Offset, $encoded.Length)
    }
    return $payload
}
function __fSyntheticPe {
    param([int]$Machine,[string[]]$Sections,[byte[]]$Payload,[string]$Path)
    $peOffset=0x80;$optionalSize=if($Machine -eq 0x014c){0xe0}else{0xf0};$sectionTable=$peOffset+4+20+$optionalSize;$rawPointer=0x400;$rawSize=0x1000
    $magic=0x20b;if($Machine -eq 0x014c){$magic=0x10b};$bytes=New-Object byte[] ($rawPointer+($Sections.Count*$rawSize));__fUInt16 -Bytes $bytes -Offset 0 -Value 0x5a4d;__fUInt32 -Bytes $bytes -Offset 0x3c -Value $peOffset;__fAscii -Bytes $bytes -Offset $peOffset -Value 'PE';__fUInt16 -Bytes $bytes -Offset ($peOffset+4) -Value $Machine;__fUInt16 -Bytes $bytes -Offset ($peOffset+6) -Value $Sections.Count;__fUInt32 -Bytes $bytes -Offset ($peOffset+20) -Value $optionalSize;__fUInt16 -Bytes $bytes -Offset ($peOffset+24) -Value $magic;__fUInt32 -Bytes $bytes -Offset ($peOffset+24+16) -Value 0x1000;__fUInt32 -Bytes $bytes -Offset ($peOffset+24+20) -Value 0x1000;__fUInt32 -Bytes $bytes -Offset ($peOffset+24+32) -Value 0x1000;__fUInt32 -Bytes $bytes -Offset ($peOffset+24+36) -Value 0x400;__fUInt32 -Bytes $bytes -Offset ($peOffset+24+56) -Value 0x5000;__fUInt32 -Bytes $bytes -Offset ($peOffset+24+60) -Value $rawPointer;__fUInt16 -Bytes $bytes -Offset ($peOffset+24+68) -Value 3;__fUInt16 -Bytes $bytes -Offset ($peOffset+24+70) -Value 0x8140
    for($index=0;$index -lt $Sections.Count;$index++){$header=$sectionTable+($index*40);__fAscii -Bytes $bytes -Offset $header -Value $Sections[$index];__fUInt32 -Bytes $bytes -Offset ($header+8) -Value $rawSize;__fUInt32 -Bytes $bytes -Offset ($header+12) -Value (0x1000+($index*0x1000));__fUInt32 -Bytes $bytes -Offset ($header+16) -Value $rawSize;__fUInt32 -Bytes $bytes -Offset ($header+20) -Value ($rawPointer+($index*$rawSize));__fUInt32 -Bytes $bytes -Offset ($header+36) -Value 0x60000020}
    [Array]::Copy($Payload,0,$bytes,$rawPointer,[Math]::Min($Payload.Length,$rawSize));[IO.File]::WriteAllBytes($Path,$bytes)
}
if(-not(Test-Path -LiteralPath $OutputDirectory)){New-Item -ItemType Directory -Path $OutputDirectory -Force|Out-Null}
$specs=@(
 @{Name='nsis.exe';Machine=0x014c;Sections=@('.text');Parts=@(@{Offset=0xbfa;Text='NullsoftInst'})},
 @{Name='inno-setup.exe';Machine=0x8664;Sections=@('.text');Parts=@(@{Offset=0x120;Text='Inno Setup Setup Data';Encoding='Unicode'})},
 @{Name='installshield.exe';Machine=0xaa64;Sections=@('.text');Parts=@(@{Offset=0x120;Text='InstallShield Setup Launcher'})},
 @{Name='squirrel.exe';Machine=0x8664;Sections=@('.text');Parts=@(@{Offset=0x120;Text='SquirrelSetup'})},
 @{Name='wix-burn.exe';Machine=0x8664;Sections=@('.text','.wixburn');Parts=@()},
 @{Name='unknown.exe';Machine=0x014c;Sections=@('.text');Parts=@()},
 @{Name='ambiguous.exe';Machine=0x8664;Sections=@('.text');Parts=@(@{Offset=0x120;Text='NullsoftInst'},@{Offset=0x180;Text='SquirrelAwareVersion'})}
)
foreach($spec in $specs){$payload=__fPayload $spec.Parts;if($spec.Name -eq 'wix-burn.exe'){__fAscii -Bytes $payload -Offset 0x120 -Value '.wixburn'};__fSyntheticPe -Machine $spec.Machine -Sections $spec.Sections -Payload $payload -Path (Join-Path $OutputDirectory $spec.Name)}
[IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'truncated.exe'),[byte[]](0x4d,0x5a,0x00,0x00));$bad=New-Object byte[] 0x200;__fUInt16 -Bytes $bad -Offset 0 -Value 0x5a4d;__fUInt32 -Bytes $bad -Offset 0x3c -Value 0x180;[IO.File]::WriteAllBytes((Join-Path $OutputDirectory 'malformed.exe'),$bad)

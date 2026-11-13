<#
  After linking, remove a static version.dll import from sift.exe and
  record its IAT RVAs in the SIFTVBIN bind table (Sift.SafeInit). At
  process start SafeInit loads System32\version.dll and fills those
  IAT slots, so a version.dll sitting next to the exe is never loaded.

  The LCL calls SysUtils.GetFileVersion, which is the source of the
  static import; we cannot change the precompiled LCL.

  Usage (one per line):
    powershell -NoProfile -File tools\Unimport-VersionDll.ps1 -Exe src\app\bin\x86_64-win64\sift.exe
#>
param(
  [Parameter(Mandatory = $true)][string]$Exe
)

$ErrorActionPreference = 'Stop'
$path = (Resolve-Path $Exe).Path
$b = [System.IO.File]::ReadAllBytes($path)
function U16($o) { [BitConverter]::ToUInt16($b, $o) }
function U32($o) { [BitConverter]::ToUInt32($b, $o) }
function U64($o) { [BitConverter]::ToUInt64($b, $o) }
function CStr($o) {
  $e = $o
  while ($b[$e] -ne 0) { $e++ }
  [System.Text.Encoding]::ASCII.GetString($b, $o, $e - $o)
}
function SetU32($o, $v) {
  $bytes = [BitConverter]::GetBytes([uint32]$v)
  [Array]::Copy($bytes, 0, $b, $o, 4)
}

$pe = U32 0x3C
if ((U32 $pe) -ne 0x4550) { throw 'not a PE file' }
$coff = $pe + 4
$nSec = U16 ($coff + 2)
$optSize = U16 ($coff + 16)
$opt = $coff + 20
$magic = U16 $opt
$is64 = ($magic -eq 0x20B)
$ddir = if ($is64) { $opt + 112 } else { $opt + 96 }
$impRva = U32 ($ddir + 8)
$secTab = $opt + $optSize
$secs = @()
for ($i = 0; $i -lt $nSec; $i++) {
  $s = $secTab + 40 * $i
  $secs += [pscustomobject]@{ Va = (U32 ($s + 12)); VSize = (U32 ($s + 8)); Raw = (U32 ($s + 20)); RawSize = (U32 ($s + 16)) }
}
function Off($rva) {
  foreach ($s in $secs) {
    $size = [Math]::Max($s.VSize, $s.RawSize)
    if ($rva -ge $s.Va -and $rva -lt ($s.Va + $size)) { return [int]($rva - $s.Va + $s.Raw) }
  }
  throw ('rva not mapped: 0x{0:X}' -f $rva)
}

# Locate the SIFTVBIN table in initialized data.
$magicBytes = [System.Text.Encoding]::ASCII.GetBytes('SIFTVBIN')
$magicOff = -1
for ($i = 0; $i -le $b.Length - $magicBytes.Length; $i++) {
  $ok = $true
  for ($k = 0; $k -lt $magicBytes.Length; $k++) {
    if ($b[$i + $k] -ne $magicBytes[$k]) { $ok = $false; break }
  }
  if ($ok) { $magicOff = $i; break }
}
if ($magicOff -lt 0) { throw 'SIFTVBIN bind table not found in the exe (is Sift.SafeInit linked first?)' }

$slots = New-Object System.Collections.Generic.List[object]
$found = $false
$foundIndex = -1
$descCount = 0
if ($impRva -eq 0) { throw 'no import directory' }
$d = Off $impRva
while ($true) {
  $oft = U32 $d; $timed = U32 ($d + 4); $chain = U32 ($d + 8); $nameRva = U32 ($d + 12); $ft = U32 ($d + 16)
  if (($oft -eq 0) -and ($nameRva -eq 0) -and ($ft -eq 0)) { break }
  $dll = (CStr (Off $nameRva)).ToLowerInvariant()
  if ($dll -eq 'version.dll') {
    $found = $true
    $foundIndex = $descCount
    $t = Off $(if ($oft -ne 0) { $oft } else { $ft })
    $n = 0
    while ($true) {
      if ($is64) {
        $v = U64 $t
        if ($v -eq 0) { break }
        if (($v -band 0x8000000000000000) -ne 0) {
          throw 'version.dll import by ordinal is not supported'
        }
        $nm = CStr ((Off ([uint32]($v -band 0x7FFFFFFF))) + 2)
        $iatRva = [uint32]($ft + 8 * $n)
        $slots.Add([pscustomobject]@{ IatRva = $iatRva; Name = $nm })
        $t += 8
      } else {
        $v = U32 $t
        if ($v -eq 0) { break }
        if (($v -band 0x80000000) -ne 0) {
          throw 'version.dll import by ordinal is not supported'
        }
        $nm = CStr ((Off $v) + 2)
        $iatRva = [uint32]($ft + 4 * $n)
        $slots.Add([pscustomobject]@{ IatRva = $iatRva; Name = $nm })
        $t += 4
      }
      $n++
    }
  }
  $descCount++
  $d += 20
}

if (-not $found) {
  # Already unimported (rebuild that did not re-link, or a second run).
  $existing = U32 ($magicOff + 8)
  if ($existing -gt 0) {
    Write-Host ("Unimport-VersionDll: already applied, {0} bind slot(s)" -f $existing)
    exit 0
  }
  throw 'version.dll is not a static import and the bind table is empty'
}

if ($slots.Count -eq 0) { throw 'version.dll import has no functions' }
if ($slots.Count -gt 8) { throw ('too many version.dll imports ({0}); raise the bind-table cap' -f $slots.Count) }

# Compact the import descriptor array: move everything after the
# version.dll entry (including the terminating zero descriptor) up one.
$firstOff = Off $impRva
$srcOff = $firstOff + 20 * ($foundIndex + 1)
$dstOff = $firstOff + 20 * $foundIndex
$remain = 20 * ($descCount - $foundIndex)  # remaining descriptors + terminator
[Array]::Copy($b, $srcOff, $b, $dstOff, $remain)

# Fill the bind table: Count at +8, then 8-byte-aligned? packed: +12 slots of 36 bytes.
SetU32 ($magicOff + 8) $slots.Count
$slotOff = $magicOff + 12
for ($i = 0; $i -lt 8; $i++) {
  $o = $slotOff + 36 * $i
  if ($i -lt $slots.Count) {
    SetU32 $o $slots[$i].IatRva
    $nb = [System.Text.Encoding]::ASCII.GetBytes($slots[$i].Name)
    if ($nb.Length -gt 31) { throw ('import name too long: {0}' -f $slots[$i].Name) }
    for ($k = 0; $k -lt 32; $k++) { $b[$o + 4 + $k] = 0 }
    [Array]::Copy($nb, 0, $b, $o + 4, $nb.Length)
  } else {
    for ($k = 0; $k -lt 36; $k++) { $b[$o + $k] = 0 }
  }
}

[System.IO.File]::WriteAllBytes($path, $b)
$names = ($slots | ForEach-Object { '{0}@0x{1:X}' -f $_.Name, $_.IatRva }) -join ', '
Write-Host ("Unimport-VersionDll: removed version.dll ({0})" -f $names)
exit 0

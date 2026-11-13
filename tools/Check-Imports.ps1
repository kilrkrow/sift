<#
  Static import and resource check for sift.exe (PE32 and PE32+), pure PowerShell, no tools needed.
  Lists every statically imported DLL!function and the exe's icon and version
  resources, and fails when:
    - the exe has no icon (no RT_GROUP_ICON, or an icon group whose images are
      missing) or no version resource; the build modes in src\app\sift.lpi run
      this script after linking, so a build without the icon fails, or
    - a DLL is imported that does not ship with Windows 7 SP1 / Server 2008 R2
      (api-ms-win-*, ext-ms-*, shcore.dll, wevtapi.dll which must be dynamic, ...), or
    - a function on the "introduced after Windows 7" list is imported statically, or
    - the PE is missing DYNAMIC_BASE (ASLR), NX_COMPAT (DEP), a .reloc section,
      or has IMAGE_FILE_RELOCS_STRIPPED set; on PE32+ HIGH_ENTROPY_VA is also
      required. These PE checks are skipped with -ResourcesOnly (harness builds).
  Usage (one per line):
    powershell -NoProfile -File tools\Check-Imports.ps1 -Exe src\app\bin\x86_64-win64\sift.exe
    powershell -NoProfile -File tools\Check-Imports.ps1 -Exe src\app\bin\i386-win32\sift.exe -OutFile docs\imports-win32.txt
#>
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [string]$OutFile = '',
  # Reviewed DLL!function pairs, all available on Windows 7 SP1 / Server 2008 R2.
  # Any static import not on this list fails the check until a person has
  # checked its "Minimum supported client" and added it.
  [string]$Allowlist = '',
  # Harness builds (not shipped) check only the icon and version resources.
  [switch]$ResourcesOnly
)
if (-not $Allowlist) { $Allowlist = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'imports-allowlist.txt' }

$ErrorActionPreference = 'Stop'
$b = [System.IO.File]::ReadAllBytes((Resolve-Path $Exe))
function U16($o) { [BitConverter]::ToUInt16($b, $o) }
function U32($o) { [BitConverter]::ToUInt32($b, $o) }
function U64($o) { [BitConverter]::ToUInt64($b, $o) }
function CStr($o) { $e = $o; while ($b[$e] -ne 0) { $e++ }; [System.Text.Encoding]::ASCII.GetString($b, $o, $e - $o) }

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
$resRva = U32 ($ddir + 16)
$secTab = $opt + $optSize
$secs = @()
$reloc = $false
for ($i = 0; $i -lt $nSec; $i++) {
  $s = $secTab + 40 * $i
  $nmBytes = New-Object byte[] 8
  [Array]::Copy($b, $s, $nmBytes, 0, 8)
  $nm = [System.Text.Encoding]::ASCII.GetString($nmBytes).Trim([char]0)
  $vs = U32 ($s + 8)
  $rs = U32 ($s + 16)
  if ($nm -eq '.reloc' -and ($vs -gt 0 -or $rs -gt 0)) { $reloc = $true }
  $secs += [pscustomobject]@{ Name = $nm; Va = (U32 ($s + 12)); VSize = $vs; Raw = (U32 ($s + 20)); RawSize = $rs }
}
$chars = U16 ($coff + 18)
$dllc = U16 ($opt + 70)
$DYNAMIC_BASE = 0x0040
$HIGH_ENTROPY_VA = 0x0020
$NX_COMPAT = 0x0100
$RELOCS_STRIPPED = 0x0001
$peInfo = 'skipped (resources only)'
function Off($rva) {
  foreach ($s in $secs) {
    $size = [Math]::Max($s.VSize, $s.RawSize)
    if ($rva -ge $s.Va -and $rva -lt ($s.Va + $size)) { return [int]($rva - $s.Va + $s.Raw) }
  }
  throw ('rva not mapped: 0x{0:X}' -f $rva)
}

$rows = New-Object System.Collections.Generic.List[string]
$dlls = New-Object System.Collections.Generic.List[string]
if ($impRva -ne 0) {
  $d = Off $impRva
  while ($true) {
    $oft = U32 $d; $nameRva = U32 ($d + 12); $ft = U32 ($d + 16)
    if ($nameRva -eq 0) { break }
    $dll = (CStr (Off $nameRva)).ToLowerInvariant()
    $dlls.Add($dll)
    $t = Off ($(if ($oft -ne 0) { $oft } else { $ft }))
    while ($true) {
      if ($is64) {
        $v = U64 $t
        if ($v -eq 0) { break }
        if (($v -band 0x8000000000000000) -ne 0) { $rows.Add("$dll!#" + ($v -band 0xFFFF)) }
        else { $rows.Add("$dll!" + (CStr ((Off ([uint32]($v -band 0x7FFFFFFF))) + 2))) }
        $t += 8
      } else {
        $v = U32 $t
        if ($v -eq 0) { break }
        if (($v -band 0x80000000) -ne 0) { $rows.Add("$dll!#" + ($v -band 0xFFFF)) }
        else { $rows.Add("$dll!" + (CStr ((Off $v) + 2))) }
        $t += 4
      }
    }
    $d += 20
  }
}

# DLLs present on a stock Windows 7 SP1 / Server 2008 R2 (Server Core included).
$win7Dlls = @('kernel32.dll','user32.dll','gdi32.dll','advapi32.dll','shell32.dll','ole32.dll','oleaut32.dll',
  'comctl32.dll','comdlg32.dll','version.dll','winspool.drv','imm32.dll','msimg32.dll','ntdll.dll','shlwapi.dll',
  'uxtheme.dll','dwmapi.dll','winmm.dll','ws2_32.dll','usp10.dll','opengl32.dll','oleacc.dll')
# Functions introduced after Windows 7 in the DLLs above (checked against the
# "Minimum supported client" of each API on learn.microsoft.com).
$post7 = @('GetDpiForWindow','GetDpiForSystem','GetSystemMetricsForDpi','AdjustWindowRectExForDpi',
  'SystemParametersInfoForDpi','SetProcessDpiAwarenessContext','SetThreadDpiAwarenessContext',
  'GetThreadDpiAwarenessContext','GetWindowDpiAwarenessContext','AreDpiAwarenessContextsEqual',
  'EnableNonClientDpiScaling','GetDpiForMonitor','SetProcessDpiAwareness','GetProcessDpiAwareness',
  'GetSystemTimePreciseAsFileTime','CreateFile2','GetCurrentThreadStackLimits','SetThreadDescription',
  'GetThreadDescription','VirtualAlloc2','MapViewOfFile3','PathCchCombine','PathCchAppend',
  'GetPointerType','GetPointerInfo','RegisterPointerInputTarget','EnableMouseInPointer',
  'IsImmersiveProcess','GetCurrentPackageId','GetCurrentPackageFullName','SetProcessMitigationPolicy',
  'GetProcessMitigationPolicy','CreateRemoteThreadEx','GetAppContainerNamedObjectPath',
  'DwmGetColorizationColor2','OpenThemeDataForDpi','GetThemeSysSize2','LoadIconWithScaleDown',
  'RegGetValueW2','PrefetchVirtualMemory','DiscardVirtualMemory','OfferVirtualMemory')

$bad = New-Object System.Collections.Generic.List[string]
if (-not $ResourcesOnly) {
foreach ($dll in $dlls) {
  if ($win7Dlls -notcontains $dll) { $bad.Add("DLL not on Windows 7 or must be dynamic: $dll") }
}
foreach ($r in $rows) {
  $fn = $r.Split('!')[1]
  if ($post7 -contains $fn) { $bad.Add("post-Windows 7 function: $r") }
}

$allowed = $null
if ($Allowlist -and (Test-Path $Allowlist)) {
  $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  Get-Content $Allowlist | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { [void]$allowed.Add($_.Trim()) }
  foreach ($r in $rows) {
    if (-not $allowed.Contains($r)) { $bad.Add("not on the reviewed Windows 7 allowlist: $r") }
  }
} else {
  $bad.Add("allowlist not found: $Allowlist")
}

# PE security flags (S1): DYNAMIC_BASE, NX_COMPAT, .reloc present,
# IMAGE_FILE_RELOCS_STRIPPED clear; HIGH_ENTROPY_VA on PE32+.
if (($dllc -band $DYNAMIC_BASE) -eq 0) { $bad.Add(('PE DllCharacteristics missing DYNAMIC_BASE (ASLR): 0x{0:X4}' -f $dllc)) }
if (($dllc -band $NX_COMPAT) -eq 0) { $bad.Add(('PE DllCharacteristics missing NX_COMPAT (DEP): 0x{0:X4}' -f $dllc)) }
if ($is64 -and (($dllc -band $HIGH_ENTROPY_VA) -eq 0)) { $bad.Add(('PE DllCharacteristics missing HIGH_ENTROPY_VA (win64): 0x{0:X4}' -f $dllc)) }
if (($chars -band $RELOCS_STRIPPED) -ne 0) { $bad.Add(('PE Characteristics has IMAGE_FILE_RELOCS_STRIPPED set: 0x{0:X4}' -f $chars)) }
if (-not $reloc) { $bad.Add('PE has no .reloc section; DYNAMIC_BASE ASLR needs relocations (link with -WR)') }
$peInfo = ('DllCharacteristics=0x{0:X4} Characteristics=0x{1:X4} DYNAMIC_BASE={2} NX_COMPAT={3} HIGH_ENTROPY_VA={4} RELOCS_STRIPPED={5} .reloc={6}' -f $dllc, $chars, [int](($dllc -band $DYNAMIC_BASE) -ne 0), [int](($dllc -band $NX_COMPAT) -ne 0), [int](($dllc -band $HIGH_ENTROPY_VA) -ne 0), [int](($chars -band $RELOCS_STRIPPED) -ne 0), [int]$reloc)
}

# ---- resources: icon groups (RT_GROUP_ICON = 14), icon images (RT_ICON = 3),
# version (RT_VERSION = 16)
$resInfo = 'none'
$groupSizes = @()
$iconIds = @()
$hasVersion = $false
if ($resRva -ne 0) {
  $root = Off $resRva
  function ResEntries($dir) {
    $n = (U16 ($dir + 12)) + (U16 ($dir + 14))
    for ($k = 0; $k -lt $n; $k++) {
      $e = $dir + 16 + 8 * $k
      [pscustomobject]@{ Id = (U32 $e); Ptr = (U32 ($e + 4)) }
    }
  }
  function ResLeaves($ptr) {
    # follow subdirectories down to IMAGE_RESOURCE_DATA_ENTRY offsets
    if (($ptr -band 0x80000000) -ne 0) {
      foreach ($c in (ResEntries ($root + ($ptr -band 0x7FFFFFFF)))) { ResLeaves $c.Ptr }
    } else { $root + $ptr }
  }
  foreach ($t in (ResEntries $root)) {
    if (($t.Id -band 0x80000000) -ne 0) { continue }
    switch ($t.Id) {
      14 {
        foreach ($leaf in (ResLeaves $t.Ptr)) {
          $g = Off (U32 $leaf)
          $cnt = U16 ($g + 4)
          $sz = @()
          for ($k = 0; $k -lt $cnt; $k++) {
            $w = $b[$g + 6 + 14 * $k]; if ($w -eq 0) { $w = 256 }
            $sz += [pscustomobject]@{ W = $w; Id = (U16 ($g + 6 + 14 * $k + 12)) }
          }
          $groupSizes += ,$sz
        }
      }
      3 {
        foreach ($c in (ResEntries ($root + ($t.Ptr -band 0x7FFFFFFF)))) { $iconIds += $c.Id }
      }
      16 { $hasVersion = $true }
    }
  }
}
if ($groupSizes.Count -eq 0) { $bad.Add('no icon: the exe has no RT_GROUP_ICON resource (was it linked without src\app\sift.ico / the project .res?)') }
foreach ($g in $groupSizes) {
  if ($g.Count -eq 0) { $bad.Add('icon group with no images') }
  foreach ($i in $g) { if ($iconIds -notcontains $i.Id) { $bad.Add("icon group refers to missing RT_ICON $($i.Id)") } }
}
if (-not $hasVersion) { $bad.Add('no version resource (RT_VERSION)') }
$resInfo = "$($groupSizes.Count) icon group(s)" + $(if ($groupSizes.Count) { ', sizes ' + (($groupSizes | ForEach-Object { ($_ | ForEach-Object { $_.W }) -join '/' }) -join '; ') } else { '' }) + ", $($iconIds.Count) icon images, version resource: $(if ($hasVersion) { 'yes' } else { 'NO' })"

$arch = if ($is64) { 'PE32+ (x64)' } else { 'PE32 (x86)' }
$report = @()
$report += "# Static imports of $(Split-Path $Exe -Leaf), $arch"
$report += "# $($dlls.Count) DLLs, $($rows.Count) functions"
$report += "# DLLs: $($dlls -join ', ')"
$report += "# resources: $resInfo"
$report += "# allowlist: $(if ($allowed) { "$($allowed.Count) reviewed pairs" } else { 'missing' })"
$report += "# PE flags: $peInfo"
$report += $rows
$report += ''
if ($bad.Count -eq 0 -and $ResourcesOnly) { $report += 'VERDICT: PASS - icon and version resources present (resources only: harness build)' }
elseif ($bad.Count -eq 0) { $report += 'VERDICT: PASS - every static import is on the reviewed Windows 7 allowlist; no post-Windows 7 DLL or function; PE ASLR/NX/reloc flags present; icon and version resources present' }
else { $report += 'VERDICT: FAIL'; $report += $bad }
if ($OutFile -ne '') { $report | Set-Content -Encoding ASCII $OutFile }
$report | Select-Object -First 4 | Select-Object -Last 2
$report | Select-Object -Last ([Math]::Max(1, $bad.Count + 1))
if ($bad.Count -ne 0) { exit 1 }

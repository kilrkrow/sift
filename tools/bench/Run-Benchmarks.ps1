<#
  Sift benchmark: siftbench.exe (the SiftCore engine, same code the viewer runs)
  vs plain Get-WinEvent, on the same machine and the same filters.

  Measures, per case:
    - time to first row  (Sift: engine first-row callback; Get-WinEvent: -MaxEvents 1)
    - time to full result (Sift: all rows, messages rendered lazily as the viewer does;
                           Get-WinEvent: all rows as EventLogRecord objects)
  Each case runs 3 times; the median is reported.

  Usage (one per line, from the repo root):
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\bench\Run-Benchmarks.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\bench\Run-Benchmarks.ps1 -BuildBigLog
  Security log case: run the same command from an elevated PowerShell (needs admin
  or Event Log Readers). Unelevated, the Security case is reported as access denied.
#>
param(
  [string]$SiftBench = 'tools\bench\bin\x86_64-win64\siftbench.exe',
  [string]$WorkDir = (Join-Path $env:TEMP 'sift-bench'),
  [switch]$BuildBigLog,
  [int]$Runs = 3,
  [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $WorkDir | Out-Null
$SiftBench = (Resolve-Path $SiftBench).Path
$big = Join-Path $WorkDir 'big.evtx'

function Median($xs) { $s = @($xs | Sort-Object); $s[[int][Math]::Floor(($s.Count - 1) / 2)] }

function Run-Sift([string[]]$SiftArgs) {
  $out = & $SiftBench @SiftArgs 2>&1 | ForEach-Object { "$_" }
  $line = $out | Where-Object { $_ -match '^run=' } | Select-Object -Last 1
  $err = $out | Where-Object { $_ -match '^channel_error' } | Select-Object -First 1
  if (-not $line) { return [pscustomobject]@{ Rows = -1; First = $null; Total = $null; Note = ($out -join ' ') } }
  $rows = [int]([regex]::Match($line, 'rows=(\d+)').Groups[1].Value)
  $first = [double]([regex]::Match($line, 'first_row_ms=([\d.]+)').Groups[1].Value)
  $total = [double]([regex]::Match($line, 'total_ms=([\d.]+)').Groups[1].Value)
  [pscustomobject]@{ Rows = $rows; First = $first; Total = $total; Note = "$err" }
}

function Time-Ms([scriptblock]$Block) { (Measure-Command $Block).TotalMilliseconds }

$cases = New-Object System.Collections.Generic.List[object]
function Add-Case($Name, [string[]]$SiftArgs, [scriptblock]$GweFirst, [scriptblock]$GweAll) {
  $cases.Add([pscustomobject]@{ Name = $Name; SiftArgs = $SiftArgs; GweFirst = $GweFirst; GweAll = $GweAll })
}

$spikeXml = @'
<QueryList>
  <Query Id="0">
    <Select Path="System">*[System[(Level=2 or Level=3 or Level=4 or Level=0) and TimeCreated[timediff(@SystemTime) &lt;= 86400000]]]</Select>
    <Select Path="Application">*[System[(Level=2 or Level=3 or Level=4 or Level=0) and TimeCreated[timediff(@SystemTime) &lt;= 86400000]]]</Select>
    <Suppress Path="System">*[System[(EventID=7036)]]</Suppress>
    <Suppress Path="Application">*[System[(EventID=7036)]]</Suppress>
  </Query>
</QueryList>
'@

Add-Case 'System, full log' @('--channel', 'System') { Get-WinEvent -LogName System -MaxEvents 1 } { (Get-WinEvent -LogName System).Count }
Add-Case 'System, last 40' @('--channel', 'System', '--last-n', '40') { Get-WinEvent -LogName System -MaxEvents 1 } { (Get-WinEvent -LogName System -MaxEvents 40).Count }
Add-Case 'System+Application, Err/Warn/Info, 24 h, exclude 7036' @('--channel', 'System', '--channel', 'Application', '--level', '2', '--level', '3', '--level', '4', '--minutes', '1440', '--exclude-id', '7036') { Get-WinEvent -FilterXml $spikeXml -MaxEvents 1 } { (Get-WinEvent -FilterXml $spikeXml).Count }
Add-Case 'Application, full log' @('--channel', 'Application') { Get-WinEvent -LogName Application -MaxEvents 1 } { (Get-WinEvent -LogName Application).Count }

if ($BuildBigLog -and -not (Test-Path $big)) {
  # Build a ~100 MB .evtx by exporting the largest local logs into one file
  # (wevtutil epl is read-only for the source logs and works unelevated).
  $logs = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object { $_.RecordCount -gt 0 -and $_.LogName -ne 'Security' } | Sort-Object FileSize -Descending | Select-Object -First 8
  $sel = ($logs | ForEach-Object { '    <Select Path="' + $_.LogName + '">*</Select>' }) -join "`r`n"
  $q = "<QueryList>`r`n  <Query Id=`"0`">`r`n$sel`r`n  </Query>`r`n</QueryList>"
  $qf = Join-Path $WorkDir 'big-query.xml'
  Set-Content -Encoding ASCII -Path $qf -Value $q
  wevtutil epl $qf $big /sq:true /ow:true
}
if (Test-Path $big) {
  $bigUri = 'file://' + $big
  $mb = [Math]::Round((Get-Item $big).Length / 1MB, 1)
  Add-Case "Exported .evtx ($mb MB), full file" @('--channel', $bigUri) { Get-WinEvent -Path $big -MaxEvents 1 } { (Get-WinEvent -Path $big).Count }
  Add-Case "Exported .evtx ($mb MB), Error+Warning" @('--channel', $bigUri, '--level', '2', '--level', '3') { Get-WinEvent -FilterHashtable @{ Path = $big; Level = 2, 3 } -MaxEvents 1 } { (Get-WinEvent -FilterHashtable @{ Path = $big; Level = 2, 3 }).Count }
}
Add-Case 'Security, full log (needs elevation)' @('--channel', 'Security') { Get-WinEvent -LogName Security -MaxEvents 1 } { (Get-WinEvent -LogName Security).Count }

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$results = foreach ($c in $cases) {
  Write-Host "case: $($c.Name)"
  $sr = @(); for ($i = 0; $i -lt $Runs; $i++) { $sr += Run-Sift $c.SiftArgs }
  $gFirst = @(); $gAll = @(); $gRows = $null; $gErr = ''
  for ($i = 0; $i -lt $Runs; $i++) {
    try {
      $gFirst += Time-Ms $c.GweFirst
      $n = $null
      $gAll += Time-Ms { $script:n = & $c.GweAll }
      $gRows = $script:n
    } catch { $gErr = $_.Exception.Message.Split("`n")[0]; break }
  }
  $ok = @($sr | Where-Object { $_.Rows -ge 0 })
  [pscustomobject]@{
    Case = $c.Name
    SiftRows = if ($ok.Count) { $ok[0].Rows } else { 'n/a' }
    SiftFirstMs = if ($ok.Count) { [Math]::Round((Median ($ok | ForEach-Object First)), 1) } else { 'n/a' }
    SiftTotalMs = if ($ok.Count) { [Math]::Round((Median ($ok | ForEach-Object Total)), 1) } else { 'n/a' }
    GweRows = if ($gErr) { 'n/a' } else { $gRows }
    GweFirstMs = if ($gErr) { 'n/a' } else { [Math]::Round((Median $gFirst), 1) }
    GweTotalMs = if ($gErr) { 'n/a' } else { [Math]::Round((Median $gAll), 1) }
    Note = (@($sr | ForEach-Object Note | Where-Object { $_ }) | Select-Object -First 1) + $(if ($gErr) { " Get-WinEvent: $gErr" } else { '' })
  }
}

$hdr = "Machine: $((Get-CimInstance Win32_OperatingSystem).Caption) $((Get-CimInstance Win32_OperatingSystem).Version), PowerShell $($PSVersionTable.PSVersion), elevated: $elevated, runs per case: $Runs (median)"
$md = @($hdr, '', '| Case | Sift rows | Sift first row (ms) | Sift full (ms) | Get-WinEvent rows | Get-WinEvent first row (ms) | Get-WinEvent full (ms) | Note |', '|---|---:|---:|---:|---:|---:|---:|---|')
foreach ($r in $results) { $md += "| $($r.Case) | $($r.SiftRows) | $($r.SiftFirstMs) | $($r.SiftTotalMs) | $($r.GweRows) | $($r.GweFirstMs) | $($r.GweTotalMs) | $($r.Note) |" }
$md | ForEach-Object { $_ }
if ($OutFile) { $md | Set-Content -Encoding ASCII $OutFile }

# Sift test fixtures: exports small .evtx files from this machine's own logs.
# Runs unelevated (wevtutil epl works without admin for System/Application).
# The .evtx files are written next to this script and are NOT committed
# (see .gitignore): they contain this machine's real events.
param(
    [int]$Count = 3000,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
foreach ($log in 'System', 'Application') {
    $out = Join-Path $here ($log.ToLower() + '.evtx')
    if ((Test-Path $out) -and -not $Force) { Write-Host "exists: $out"; continue }
    $oldest = Get-WinEvent -LogName $log -MaxEvents $Count | Select-Object -Last 1
    $query = "*[System[EventRecordID>=$($oldest.RecordId)]]"
    wevtutil epl $log $out "/q:$query" /ow:true
    if ($LASTEXITCODE -ne 0) { throw "wevtutil epl $log failed: $LASTEXITCODE" }
    Write-Host "wrote: $out ($((Get-Item $out).Length) bytes)"
}
# Optional: events from the dedicated SiftTest source (see Register-SiftTestSource.ps1).
$st = Join-Path $here 'sifttest.evtx'
if (-not (Test-Path $st) -or $Force) {
    $have = @()
    try { $have = @(Get-WinEvent -FilterXml "<QueryList><Query Id='0' Path='Application'><Select Path='Application'>*[System[Provider[@Name='SiftTest']]]</Select></Query></QueryList>" -MaxEvents 1 -ErrorAction Stop) } catch { $have = @() }
    if ($have.Count -gt 0) {
        wevtutil epl Application $st "/q:*[System[Provider[@Name='SiftTest']]]" /ow:true
        Write-Host "wrote: $st"
    } else {
        Write-Host 'skipped: sifttest.evtx (SiftTest source not registered or no events; see Register-SiftTestSource.ps1)'
    }
}

# Writes known events from the SiftTest source into the Application log.
# Needs Register-SiftTestSource.ps1 to have been run once (elevated). Writing
# to Application itself does not need admin.
# -SpreadMinutes spreads the writes over that many minutes (e.g. 240 for the
# 1 min .. 4 h windows); 0 writes them all now.
param([int]$SpreadMinutes = 0)
$ErrorActionPreference = 'Stop'
$plan = @(
    @{ Id = 1000; Type = 'Information'; Msg = 'Sift fixture: plain information' },
    @{ Id = 1001; Type = 'Warning';     Msg = 'Sift fixture: warning with "quotes" & ampersand' },
    @{ Id = 1002; Type = 'Error';       Msg = 'Sift fixture: error <angle> brackets' },
    @{ Id = 1003; Type = 'Information'; Msg = "Sift fixture: O'Brien apostrophe" },
    @{ Id = 1004; Type = 'Warning';     Msg = 'Sift fixture: USB device not recognized (demo text)' },
    @{ Id = 1005; Type = 'Error';       Msg = 'Sift fixture: disk error on volume E:' },
    @{ Id = 1006; Type = 'Information'; Msg = 'Sift fixture: multi-line first line' + [Environment]::NewLine + 'second line' }
)
$offsets = @(0, 1, 4, 14, 29, 59, 239)
$start = Get-Date
for ($i = 0; $i -lt $plan.Count; $i++) {
    if ($SpreadMinutes -gt 0) {
        $due = $start.AddMinutes([Math]::Min($offsets[$i], $SpreadMinutes))
        while ((Get-Date) -lt $due) { Start-Sleep -Seconds 5 }
    }
    $p = $plan[$i]
    Write-EventLog -LogName Application -Source SiftTest -EventId $p.Id -EntryType $p.Type -Message $p.Msg
}
Write-Host "wrote $($plan.Count) SiftTest events"

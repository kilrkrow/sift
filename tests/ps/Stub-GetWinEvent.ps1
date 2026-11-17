<#
  Test stub for Get-WinEvent (issue #8 checks). Dot-source it; it defines a
  global Get-WinEvent that reads no log. It logs the FilterHashtable it got
  to $env:SIFT_STUB_LOG (key=base64,...;key=...) and returns two events:
  RecordId/Id 101 whose Message contains the decoded $env:SIFT_STUB_MSG,
  and 202 whose Message does not.
#>
function global:Get-WinEvent {
  [CmdletBinding()]
  param([hashtable]$FilterHashtable, [object]$FilterXml, [long]$MaxEvents)
  $enc = New-Object System.Text.UTF8Encoding($false)
  if ($env:SIFT_STUB_LOG -and $FilterHashtable) {
    $parts = @()
    foreach ($k in @($FilterHashtable.Keys | Sort-Object)) {
      $vals = @($FilterHashtable[$k] | ForEach-Object { [System.Convert]::ToBase64String($enc.GetBytes([string]$_)) })
      $parts += ($k + '=' + ($vals -join ','))
    }
    [System.IO.File]::AppendAllText($env:SIFT_STUB_LOG, ($parts -join ';') + "`r`n", $enc)
  }
  $m = ''
  if ($env:SIFT_STUB_MSG) { $m = $enc.GetString([System.Convert]::FromBase64String($env:SIFT_STUB_MSG)) }
  foreach ($e in @(@(101, ('prefix ' + $m + ' suffix')), @(202, 'unrelated text'))) {
    [pscustomobject]@{
      PSTypeName = 'Sift.StubEvent'; RecordId = $e[0]; Id = $e[0]; Message = $e[1]
      TimeCreated = [datetime]'2026-01-01'; LevelDisplayName = 'Information'
      LogName = 'StubLog'; ProviderName = 'StubProv'
    }
  }
}
Update-TypeData -TypeName Sift.StubEvent -DefaultDisplayPropertySet RecordId, ProviderName -Force

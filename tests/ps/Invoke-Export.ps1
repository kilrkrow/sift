<#
  -File runner for the issue #8 checks: loads the Get-WinEvent stub, then
  runs the exported script file (read by the shell's script-file reader,
  BOM detection included, the same as -File).
#>
param([Parameter(Mandatory = $true)][string]$Target)
. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Stub-GetWinEvent.ps1')
& $Target

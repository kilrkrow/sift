<#
  Post-link for every sift.exe build mode: unimport version.dll (S3 /
  BAR 12), then run Check-Imports. -ResourcesOnly is forwarded so
  harness builds still skip the import and PE-flag checks.
#>
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [switch]$ResourcesOnly
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$un = Join-Path $here 'Unimport-VersionDll.ps1'
$ci = Join-Path $here 'Check-Imports.ps1'
& $un -Exe $Exe
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($ResourcesOnly) {
  & $ci -Exe $Exe -ResourcesOnly
} else {
  & $ci -Exe $Exe
}
exit $LASTEXITCODE

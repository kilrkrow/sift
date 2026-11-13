# ONE-TIME ELEVATED STEP (needs the maintainer): registers the dedicated "SiftTest" event
# source in the Application log so Write-SiftTestEvents.ps1 can write known
# events. Run in an elevated Windows PowerShell:
#   New-EventLog -LogName Application -Source SiftTest
# To remove it later (also elevated):
#   Remove-EventLog -Source SiftTest
New-EventLog -LogName Application -Source SiftTest

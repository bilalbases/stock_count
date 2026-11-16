# Registers the "StockCountServer" task (called by Install.cmd).
# - starts at Windows startup, as SYSTEM (no login needed)
# - NO 3-day time limit (Windows stops tasks after 72 hours by default)
# - watchdog: every 5 minutes it is started again if it is not running (e.g. after a crash)
param([string]$Dir)
$ErrorActionPreference = 'Stop'
$script = Join-Path $Dir 'StockCountServer.ps1'
$act   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"" -WorkingDirectory $Dir
$boot  = New-ScheduledTaskTrigger -AtStartup
$watch = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$set   = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
           -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
           -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$who   = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName 'StockCountServer' -Action $act -Trigger $boot, $watch -Settings $set -Principal $who -Force | Out-Null
Write-Host 'Task registered (no time limit, restarts automatically).'

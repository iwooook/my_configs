# Register seatwatch as a scheduled task (no admin needed).
# - Starts at logon, and re-checks every 10 minutes (restarts it if it died / after sleep).
# - MultipleInstances=IgnoreNew, so only one watcher ever runs.
# - Triggers expire at config.json "until", and watch.py itself exits at that time.
# Usage: powershell -ExecutionPolicy Bypass -File .\install-task.ps1
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$taskName = 'SeatWatch'
$cfg = Get-Content -Raw -Encoding UTF8 (Join-Path $here 'config.json') | ConvertFrom-Json

# venv + playwright (browser = installed Edge, so no 'playwright install' needed)
$py = Join-Path $here '.venv\Scripts\python.exe'
if (-not (Test-Path $py)) {
    Write-Host 'Creating venv + installing playwright...'
    python -m venv (Join-Path $here '.venv')
    & $py -m pip install -q playwright
}
$pyw = Join-Path $here '.venv\Scripts\pythonw.exe'

$action = New-ScheduledTaskAction -Execute $pyw -Argument ('"' + (Join-Path $here 'watch.py') + '"') -WorkingDirectory $here

$start = (Get-Date).AddMinutes(1)
$repeat = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes 10)
$logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$triggers = @($repeat, $logon)
if ($cfg.until) {
    $end = [datetime]::ParseExact($cfg.until, 'yyyy-MM-dd HH:mm', $null).ToString('s')
    foreach ($t in $triggers) { $t.EndBoundary = $end }
}

$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DontStopOnIdleEnd -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $settings `
        -Principal $principal -Description 'NOL ticket seat watcher (my_configs/ntfy/seatwatch)' -Force | Out-Null
} catch {
    # Some machines refuse AtLogOn triggers without admin; the 10-min repeat alone still covers logon.
    Write-Host "AtLogOn trigger refused ($($_.Exception.Message.Trim())); using 10-min repeat only."
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $repeat -Settings $settings `
        -Principal $principal -Description 'NOL ticket seat watcher (my_configs/ntfy/seatwatch)' -Force | Out-Null
}
Start-ScheduledTask -TaskName $taskName
Write-Host "Registered and started task '$taskName'. Log: $(Join-Path $here 'watch.log')"

# Daily health report to ntfy at 10:00 (runs late if the PC was off/asleep at 10:00).
$healthName = 'SeatWatch-Health'
$hAction = New-ScheduledTaskAction -Execute $pyw -Argument ('"' + (Join-Path $here 'health.py') + '"') -WorkingDirectory $here
$hTrigger = New-ScheduledTaskTrigger -Daily -At '10:00'
if ($cfg.until) { $hTrigger.EndBoundary = $end }
$hSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $healthName -Action $hAction -Trigger $hTrigger -Settings $hSettings `
    -Principal $principal -Description 'Daily seatwatch health report via ntfy' -Force | Out-Null
Write-Host "Registered task '$healthName' (daily 10:00 ntfy report)."

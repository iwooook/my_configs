# Stop seatwatch and remove its scheduled task.
# Usage: powershell -ExecutionPolicy Bypass -File .\uninstall-task.ps1
$taskName = 'SeatWatch'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed task '$taskName'."
}
& (Join-Path $PSScriptRoot 'kill-watcher.ps1')

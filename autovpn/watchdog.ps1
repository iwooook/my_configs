# AutoVPN watchdog -- restarts the supervisor if it died unexpectedly.
#
# Runs on a repeating schedule (task: AutoVPN-Watchdog). Deliberately dumb and
# cheap: it does not touch openconnect or the tunnel, it only answers one
# question -- is the supervisor supposed to be running, and is it?
#
# The halt flag is what keeps "restart if it dies" from becoming a retry loop
# against rejected credentials. vpn-auto.ps1 writes it when it quits on
# purpose; only a proven-healthy connection or setup-cred.ps1 clears it.

$log  = "$env:LOCALAPPDATA\AutoVPN\watchdog.log"
$halt = "$env:LOCALAPPDATA\AutoVPN\halt.reason"

function W($m) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m"
    try {
        if ((Test-Path $log) -and ((Get-Item $log).Length -gt 1MB)) {
            Move-Item $log "$log.1" -Force
        }
        Add-Content $log $line -Encoding utf8
    } catch { }
}

try {
    $task = Get-ScheduledTask -TaskName 'AutoVPN' -ErrorAction Stop
} catch {
    W 'AutoVPN task not found -- nothing to supervise'
    exit 0
}

if ($task.State -eq 'Running') { exit 0 }   # healthy: stay silent

if (-not $task.Settings.Enabled) {
    W 'AutoVPN task is disabled -- not starting (assumed intentional)'
    exit 0
}

if (Test-Path $halt) {
    $reason = (Get-Content $halt -Raw -ErrorAction SilentlyContinue).Trim()
    W "supervisor is down but halted on purpose -- NOT restarting. reason: $reason"
    exit 0
}

# Not running, not disabled, no halt flag => it died unexpectedly.
W "supervisor is not running and no halt flag present -- restarting"
try {
    Start-ScheduledTask -TaskName 'AutoVPN' -ErrorAction Stop
    Start-Sleep -Seconds 5
    W "restart issued; task state now: $((Get-ScheduledTask -TaskName 'AutoVPN').State)"
} catch {
    W "restart FAILED: $($_.Exception.Message)"
}

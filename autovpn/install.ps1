<#
  AutoVPN installer.

  Sets up moreh VPN auto-connect on this machine:
    - registers the AutoVPN task            (logon / wake / unlock triggers,
                                              elevated)
    - registers the AutoVPN-Watchdog task    (every minute, restarts a crashed
                                              supervisor)
    - prompts for the VPN password and stores it DPAPI-encrypted

  Run it from wherever this folder lives:

      powershell -ExecutionPolicy Bypass -File .\install.ps1

  It re-launches itself elevated if needed (task registration and openconnect's
  virtual adapter both require it), so expect one UAC prompt.

  Note: the stored credential is DPAPI-encrypted against THIS user on THIS
  machine. It cannot be copied to another PC -- run this installer there
  instead. Everything else (CA bundle, logs) is regenerated automatically.
#>

[CmdletBinding()]
param(
    # Set internally when the script re-launches itself with elevation.
    [switch]$Elevated,
    # Skip the password prompt (e.g. re-registering tasks only).
    [switch]$SkipCredential
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$Supervisor = Join-Path $here 'vpn-auto.ps1'
$Watchdog   = Join-Path $here 'watchdog.ps1'
$StateDir   = "$env:LOCALAPPDATA\AutoVPN"
$CredFile   = "$StateDir\cred.dpapi"
$HaltFile   = "$StateDir\halt.reason"

function Fail($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }
function Ok($m)   { Write-Host "  $m" -ForegroundColor Green }
function Info($m) { Write-Host "  $m" -ForegroundColor Gray }

Write-Host ''
Write-Host 'AutoVPN installer' -ForegroundColor Cyan
Write-Host "source: $here"
Write-Host ''

# ------------------------------------------------------------ sanity checks
foreach ($f in @($Supervisor, $Watchdog)) {
    if (-not (Test-Path $f)) { Fail "missing file: $f" }
}

$ocPaths = @(
    "$env:ProgramFiles\OpenConnect-GUI\openconnect.exe"
    "${env:ProgramFiles(x86)}\OpenConnect-GUI\openconnect.exe"
    "$env:LOCALAPPDATA\Programs\OpenConnect-GUI\openconnect.exe"
)
$oc = $ocPaths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $oc) { $oc = (Get-Command 'openconnect.exe' -ErrorAction SilentlyContinue).Source }
if (-not $oc) {
    Write-Host 'openconnect not found. Install OpenConnect-GUI first:' -ForegroundColor Red
    Write-Host '  https://github.com/openconnect/openconnect-gui/releases' -ForegroundColor Red
    exit 1
}
Ok "openconnect: $oc"

# ------------------------------------------------------------ elevate
$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

if (-not $isAdmin) {
    if ($Elevated) { Fail 'relaunched but still not elevated -- aborting' }
    Write-Host ''
    Write-Host 'Task registration needs admin rights. Approve the UAC prompt...' -ForegroundColor Yellow
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Elevated'
    )
    if ($SkipCredential) { $argList += '-SkipCredential' }
    $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -PassThru -Wait
    if ($p.ExitCode -ne 0) { Fail "elevated run failed (exit $($p.ExitCode))" }
    Write-Host ''
    Write-Host 'Tasks registered. Now storing the credential as your own user...' -ForegroundColor Cyan
    # Credential must be written NON-elevated, or DPAPI binds it to the wrong
    # profile when UAC is configured with a separate admin account.
    if (-not $SkipCredential) { & (Join-Path $here 'setup-cred.ps1') }
    exit 0
}

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# ------------------------------------------------------------ AutoVPN task
Write-Host ''
Write-Host 'registering AutoVPN...' -ForegroundColor Cyan

# A running instance keeps the settings it was started with, so stop it first;
# the supervisor's finally blocks take openconnect down with it and the fresh
# instance started at the end of this script runs under the new definition.
$existing = Get-ScheduledTask -TaskName 'AutoVPN' -ErrorAction SilentlyContinue
if ($existing -and $existing.State -eq 'Running') {
    Info 'stopping the running supervisor so it picks up the new settings'
    Stop-ScheduledTask -TaskName 'AutoVPN' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Get-Process -Name openconnect -ErrorAction SilentlyContinue |
        ForEach-Object { try { $_.Kill() } catch { } }
}

# The Task Scheduler history log is off by default on client Windows. Turn it
# on so the next unexplained stop shows *who* stopped the task (event 111/201/
# 202) instead of leaving only a gap in autovpn.log. Best effort.
try {
    & wevtutil.exe sl Microsoft-Windows-TaskScheduler/Operational /e:true 2>$null
    Ok 'Task Scheduler history enabled'
} catch { Info 'could not enable Task Scheduler history (non-fatal)' }

$user = "$env:USERDOMAIN\$env:USERNAME"
# When elevated via UAC the user is unchanged, but be explicit about the SID's
# account name so the task is owned by the interactive user, not "Administrator".
$targetUser = $env:USERNAME

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Supervisor`""

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $targetUser
$logonTrigger.Delay = 'PT30S'      # let the network actually come up before dialling

# Wake-from-sleep kills the previous session but raises no logon event, so with
# a logon-only trigger nothing redials until the watchdog's next slot (observed
# 2026-08-18: woke 21:28, VPN back only at 21:35). React to the resume event
# itself instead. Delay lets Wi-Fi reassociate first; the supervisor's
# pre-flight handles the case where it hasn't.
$evtClass = Get-CimClass MSFT_TaskEventTrigger Root/Microsoft/Windows/TaskScheduler
$wakeTrigger = New-CimInstance -CimClass $evtClass -ClientOnly -Property @{
    Enabled      = $true
    Delay        = 'PT15S'
    Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Power-Troubleshooter''] and EventID=1]]</Select></Query></QueryList>'
}

# Unlock covers wakes we somehow missed (and the common "opened the laptop"
# case where unlock follows resume anyway -- duplicate fires are harmless: the
# task is IgnoreNew and the supervisor holds a global mutex).
$sscClass = Get-CimClass MSFT_TaskSessionStateChangeTrigger Root/Microsoft/Windows/TaskScheduler
$unlockTrigger = New-CimInstance -CimClass $sscClass -ClientOnly -Property @{
    Enabled     = $true
    Delay       = 'PT5S'
    StateChange = 8              # TASK_SESSION_UNLOCK
    UserId      = $targetUser
}

# New-ScheduledTaskSettingsSet defaults the battery flags to "don't start /
# stop on battery". On a laptop that alone looks like random VPN failures.
#
# RestartCount is deliberately left at 0: the supervisor exits non-zero only on
# faults it decided NOT to retry (notably rejected credentials). Scheduler-level
# restarts would defeat that guard -- AutoVPN-Watchdog handles crash recovery
# instead, and it honours the halt flag.
#
# -DontStopOnIdleEnd is essential. New-ScheduledTaskSettingsSet silently emits
# <StopOnIdleEnd>true</StopOnIdleEnd> ("Stop if the computer ceases to be
# idle"), and that applies to ANY running instance, not only idle-triggered
# ones. Modern standby is the perfect idle state (no input, no CPU), so the
# moment the user came back from a nap the scheduler stopped the supervisor --
# no log line, tunnel gone, and the VPN only returned when the watchdog noticed
# up to a minute later. Observed on every resume from 2026-08-19 to 2026-09-22.
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -RunOnlyIfNetworkAvailable `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

# Highest: openconnect must create the virtual adapter and set routes.
$principal = New-ScheduledTaskPrincipal -UserId $targetUser -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName 'AutoVPN' -Action $action `
    -Trigger @($logonTrigger, $wakeTrigger, $unlockTrigger) `
    -Settings $settings -Principal $principal -Force | Out-Null
Ok 'AutoVPN registered (logon +30s / wake +15s / unlock +5s, elevated, network-gated)'

# ------------------------------------------------------------ watchdog task
Write-Host ''
Write-Host 'registering AutoVPN-Watchdog...' -ForegroundColor Cyan

$wAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Watchdog`""

# Past start boundary + StartWhenAvailable => repetition window is live at once.
$wTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(-1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$wSettings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -Hidden

# Least privilege: the watchdog only calls Start-ScheduledTask. The scheduler
# still runs AutoVPN at its own RunLevel (Highest).
#
# S4U instead of Interactive: an Interactive powershell.exe task flashes a
# console window on every run even with -WindowStyle Hidden (the console
# is created before PowerShell can hide it). S4U runs in session 0 -- no
# window at all -- and the watchdog needs no UI and no DPAPI access.
$wPrincipal = New-ScheduledTaskPrincipal -UserId $targetUser -LogonType S4U -RunLevel Limited

Register-ScheduledTask -TaskName 'AutoVPN-Watchdog' -Action $wAction -Trigger $wTrigger `
    -Settings $wSettings -Principal $wPrincipal -Force | Out-Null
Ok 'AutoVPN-Watchdog registered (every minute, honours halt flag)'

# ------------------------------------------------------------ report
Write-Host ''
Write-Host 'installed:' -ForegroundColor Cyan
foreach ($n in 'AutoVPN', 'AutoVPN-Watchdog') {
    $t = Get-ScheduledTask -TaskName $n
    Info ("{0,-18} state={1}  runlevel={2}  user={3}" -f $n, $t.State, $t.Principal.RunLevel, $t.Principal.UserId)
}
Info "state dir : $StateDir"
Info "log       : $StateDir\autovpn.log"

if (Test-Path $HaltFile) {
    Remove-Item $HaltFile -Force
    Ok 'cleared stale halt flag'
}

Write-Host ''
if (Test-Path $CredFile) {
    Ok 'credential already stored -- starting AutoVPN'
    Start-ScheduledTask -TaskName 'AutoVPN'
    Write-Host ''
    Write-Host "follow with:  Get-Content `"$StateDir\autovpn.log`" -Tail 40 -Wait" -ForegroundColor Cyan
} else {
    Write-Host 'Next: store the VPN password (this window is elevated, so do it' -ForegroundColor Yellow
    Write-Host 'in your NORMAL terminal to bind DPAPI to the right profile):' -ForegroundColor Yellow
    Write-Host ''
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$(Join-Path $here 'setup-cred.ps1')`"" -ForegroundColor White
}
Write-Host ''

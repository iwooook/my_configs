<#
  Removes AutoVPN from this machine.

      powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
      powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -KeepState

  Stops the tunnel, unregisters both tasks, and deletes the state directory
  (credential, CA bundle, logs). -KeepState leaves the state directory alone.
#>

[CmdletBinding()]
param([switch]$Elevated, [switch]$KeepState)

$ErrorActionPreference = 'Continue'
$StateDir = "$env:LOCALAPPDATA\AutoVPN"

$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

if (-not $isAdmin) {
    if ($Elevated) { Write-Host 'still not elevated -- aborting' -ForegroundColor Red; exit 1 }
    Write-Host 'Unregistering tasks needs admin rights. Approve the UAC prompt...' -ForegroundColor Yellow
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Elevated')
    if ($KeepState) { $a += '-KeepState' }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $a -Wait
    exit 0
}

Write-Host ''
foreach ($n in 'AutoVPN-Watchdog', 'AutoVPN') {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
    if ($t) {
        if ($t.State -eq 'Running') { Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue }
        Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  unregistered $n" -ForegroundColor Green
    } else {
        Write-Host "  $n not present" -ForegroundColor Gray
    }
}

Get-Process -Name openconnect -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_.Kill(); Write-Host "  killed openconnect (pid $($_.Id))" -ForegroundColor Green } catch { }
}

if ($KeepState) {
    Write-Host "  kept state dir: $StateDir" -ForegroundColor Gray
} elseif (Test-Path $StateDir) {
    Remove-Item $StateDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  removed state dir: $StateDir" -ForegroundColor Green
}

Write-Host ''
Write-Host 'done. Scripts in this folder were not touched.' -ForegroundColor Cyan
Write-Host ''

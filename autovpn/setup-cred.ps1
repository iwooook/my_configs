# One-shot setup: store the VPN password (DPAPI), verify it round-trips,
# then start the supervisor and follow the log.
#
# Must be run interactively, NOT elevated, as the account that owns the AutoVPN
# task. DPAPI ties the ciphertext to this user on this machine, so a credential
# written by any other account cannot be decrypted by the task -- and it cannot
# be copied to another PC. Re-run this on each machine.

$ErrorActionPreference = 'Stop'
$dir  = "$env:LOCALAPPDATA\AutoVPN"
$cred = "$dir\cred.dpapi"
$log  = "$dir\autovpn.log"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Write-Host ''
Write-Host 'AutoVPN credential setup' -ForegroundColor Cyan
Write-Host "user: jungwook @ vpn.moreh.dev:20022"
Write-Host ''

$sec = Read-Host 'VPN password' -AsSecureString
if ($sec.Length -eq 0) { Write-Host 'empty password, aborted.' -ForegroundColor Red; exit 1 }

# ConvertFrom-SecureString yields a plain hex string. Write it as ASCII with
# no BOM: Set-Content -Encoding utf8 emits a BOM under Windows PowerShell 5.1,
# and that BOM makes ConvertTo-SecureString fail to parse the hex on the way
# back in. The scheduled task runs powershell.exe (5.1), so this matters.
[IO.File]::WriteAllText($cred, ($sec | ConvertFrom-SecureString), (New-Object Text.UTF8Encoding($false)))

# Prove it decrypts back before handing it to the supervisor, so a bad write
# surfaces here rather than as a login failure against the gateway.
try {
    $rt   = ([IO.File]::ReadAllText($cred)).TrimStart([char]0xFEFF).Trim() | ConvertTo-SecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($rt)
    try { $len = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Length }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if ($len -eq 0) { throw 'decrypted to an empty string' }
    Write-Host "stored and verified ($len chars decrypt OK)" -ForegroundColor Green
} catch {
    Write-Host "verification FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'not starting the task.' -ForegroundColor Red
    exit 1
}

# Lock the file down to this user only.
try {
    $acl = Get-Acl $cred
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        "$env:USERDOMAIN\$env:USERNAME", 'FullControl', 'Allow')))
    Set-Acl $cred $acl
    Write-Host 'file ACL restricted to current user' -ForegroundColor Green
} catch {
    Write-Host "could not tighten ACL: $($_.Exception.Message)" -ForegroundColor Yellow
}

# A new password is a reason to try again, so lift any halt the supervisor set
# after rejected credentials -- otherwise the watchdog would keep refusing to
# restart it.
$halt = "$dir\halt.reason"
if (Test-Path $halt) {
    Remove-Item $halt -Force
    Write-Host 'cleared halt flag (was blocking auto-restart)' -ForegroundColor Green
}

Write-Host ''
Write-Host 'starting AutoVPN task...' -ForegroundColor Cyan
Start-ScheduledTask -TaskName 'AutoVPN'
Start-Sleep -Seconds 3

Write-Host ''
Write-Host "following $log  (Ctrl+C to stop -- the VPN keeps running)" -ForegroundColor Cyan
Write-Host ('-' * 72)
Get-Content $log -Tail 40 -Wait

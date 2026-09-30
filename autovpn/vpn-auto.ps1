#Requires -Version 5.1
<#
  AutoVPN supervisor for openconnect  (Fortinet / vpn.moreh.dev)

  Replaces vpn-auto.vbs, which hard-looped every 3s with no logging and no
  error handling. On 2026-08-03 the gateway started serving an incomplete
  certificate chain (leaf only, no Sectigo intermediate); openconnect/GnuTLS
  does not fetch intermediates over AIA, so every attempt failed instantly and
  the 3s loop escalated a server-side fault into an IP ban from the gateway's
  brute-force protection.

  Design goal: keep working while the gateway misbehaves.

  Gateway faults this survives
    incomplete cert chain ....... rebuilds a CA bundle via AIA (.NET follows
                                  AIA where GnuTLS won't), then falls back to
                                  identity-checked pinning
    cert rotation ............... CA bundle is intermediate-based, so leaf
                                  renewals don't break it; pin is re-learned
    gateway blocking us ......... told apart from "our network is down", and
                                  answered with a long cooldown, since
                                  retrying is what extends a ban
    gateway down / flapping ..... backoff with jitter + circuit breaker
    transient 5xx / bad forms ... treated as retryable, never as auth failure
    flaky UDP (DTLS) ............ auto-retries with DTLS disabled when
                                  sessions keep dying young
    black-holed tunnel .......... watchdog probes the tunnel while connected
                                  and restarts it if traffic stops passing
    system sleep/resume ......... a resume is detected as a wall-clock jump in
                                  the pump loop; the dead session is killed and
                                  redialled at once instead of waiting for the
                                  health probe to fail 3 times (~90s) while
                                  openconnect retries a session the gateway
                                  will never resume (reconnect-after-drop is
                                  not allowed)
    genuinely wrong password .... stops, rather than looping into a lockout
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------ locate binary
# Resolved at runtime rather than hardcoded, so this script works unchanged on
# another machine where OpenConnect-GUI landed somewhere else.
function Find-OpenConnect {
    $candidates = @(
        "$env:ProgramFiles\OpenConnect-GUI\openconnect.exe"
        "${env:ProgramFiles(x86)}\OpenConnect-GUI\openconnect.exe"
        "$env:LOCALAPPDATA\Programs\OpenConnect-GUI\openconnect.exe"
        "$env:ProgramFiles\OpenConnect\openconnect.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command 'openconnect.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return "$env:ProgramFiles\OpenConnect-GUI\openconnect.exe"   # report this path when missing
}

# ---------------------------------------------------------------- config
$Cfg = @{
    Exe        = Find-OpenConnect
    Server     = 'vpn.moreh.dev:20022'
    ServerHost = 'vpn.moreh.dev'
    ServerPort = 20022
    Protocol   = 'fortinet'
    User       = 'jungwook'

    StateDir = "$env:LOCALAPPDATA\AutoVPN"
    CredFile = "$env:LOCALAPPDATA\AutoVPN\cred.dpapi"
    CaBundle = "$env:LOCALAPPDATA\AutoVPN\moreh-chain.pem"
    PinFile  = "$env:LOCALAPPDATA\AutoVPN\servercert.pin"
    LogFile  = "$env:LOCALAPPDATA\AutoVPN\autovpn.log"
    LogMaxMB = 5
    LogKeep  = 3

    # Written when this supervisor gives up on purpose (bad credentials, no
    # credential, missing binary). The watchdog task refuses to auto-restart
    # while it exists, so "restart if it dies" cannot turn into a retry loop
    # against rejected credentials. Cleared once a session proves healthy, or
    # by setup-cred.ps1 when the password is updated.
    HaltFile = "$env:LOCALAPPDATA\AutoVPN\halt.reason"

    # Let openconnect ride out brief drops itself instead of paying a full
    # re-auth for every hiccup.
    ReconnectTimeout = 300

    BackoffBaseSec = 10
    BackoffFactor  = 2
    BackoffMaxSec  = 600
    JitterPct      = 20

    # A session lasting this long counts as "it worked" -> reset all counters.
    HealthySec = 60

    BreakerThreshold = 5
    BreakerSleepSec  = 1800

    # Cooldown when the gateway is actively refusing us. Deliberately long:
    # Fortinet's block extends every time you knock while banned.
    BlockedCooldownSec = 900

    # Definitive auth rejections tolerated before giving up for good.
    MaxAuthFailures = 2

    # --- tunnel watchdog -------------------------------------------------
    # An internal host only reachable over the VPN, so the watchdog checks
    # "does traffic actually pass" rather than merely "is the adapter up" --
    # that is what catches a black-holed tunnel. 10.40.10.50:22 arrives as a
    # /32 split route from the gateway and answers in ~10ms.
    #
    # This probe doubles as a keepalive. The gateway reports "Idle timeout is
    # 60 minutes", and since it also reports "reconnect-after-drop is not
    # allowed", an idle drop costs a full re-auth. Traffic every 30s prevents
    # the tunnel from ever going idle.
    HealthProbeHost    = '10.40.10.50'
    HealthProbePort    = 22
    HealthIntervalSec  = 30
    HealthFailsToKill  = 3

    # Sessions shorter than this, repeatedly, suggest a transport problem
    # (usually flaky UDP/DTLS) rather than a clean drop.
    YoungSessionSec    = 45
    YoungBeforeNoDtls  = 3
}

$expectedCertCn     = '*.moreh.dev'
$expectedCertIssuer = 'Sectigo'

# ---------------------------------------------------------------- logging
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO')
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if ((Test-Path $Cfg.LogFile) -and ((Get-Item $Cfg.LogFile).Length -gt $Cfg.LogMaxMB * 1MB)) {
            for ($i = $Cfg.LogKeep; $i -ge 1; $i--) {
                $src = if ($i -eq 1) { $Cfg.LogFile } else { "$($Cfg.LogFile).$($i - 1)" }
                if (Test-Path $src) { Move-Item $src "$($Cfg.LogFile).$i" -Force }
            }
        }
        Add-Content -Path $Cfg.LogFile -Value $line -Encoding utf8
    } catch { }
    Write-Host $line
}

# ------------------------------------------------------------ halt state
# Distinguishes "crashed, please restart me" from "I quit on purpose, leave me
# alone". Without this, any restart mechanism would defeat the account-lockout
# guard by re-running rejected credentials forever.
function Set-Halt {
    param([string]$Reason)
    try {
        Set-Content -Path $Cfg.HaltFile -Encoding utf8 `
            -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Reason"
        Write-Log "halt flag set -- watchdog will not auto-restart: $Reason" 'WARN'
    } catch { }
}

function Clear-Halt {
    try {
        if (Test-Path $Cfg.HaltFile) {
            Remove-Item $Cfg.HaltFile -Force
            Write-Log 'halt flag cleared (connection proven healthy)' 'OK'
        }
    } catch { }
}

# ------------------------------------------------------- server identity
# Fetch the leaf directly and confirm it's really the host we expect. Used
# both to rebuild the CA bundle and to sanity-check before trusting a pin,
# so a broken chain never means "trust anything".
function Get-ServerLeaf {
    $tcp = $null; $ssl = $null
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        if (-not $tcp.ConnectAsync($Cfg.ServerHost, $Cfg.ServerPort).Wait(8000)) { return $null }
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($Cfg.ServerHost)
        return New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
    } catch {
        Write-Log "could not fetch server certificate: $($_.Exception.Message)" 'WARN'
        return $null
    } finally {
        if ($ssl) { try { $ssl.Dispose() } catch { } }
        if ($tcp) { try { $tcp.Close() } catch { } }
    }
}

function Test-LeafIdentity {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Leaf)
    if (-not $Leaf) { return $false }
    if ($Leaf.Subject -notlike "*CN=$expectedCertCn*") {
        Write-Log "cert CN mismatch: $($Leaf.Subject)" 'ERROR'; return $false
    }
    if ($Leaf.Issuer -notmatch $expectedCertIssuer) {
        Write-Log "cert issuer unexpected: $($Leaf.Issuer)" 'ERROR'; return $false
    }
    $now = Get-Date
    if ($now -lt $Leaf.NotBefore -or $now -gt $Leaf.NotAfter) {
        Write-Log "cert outside validity window ($($Leaf.NotBefore) .. $($Leaf.NotAfter))" 'ERROR'; return $false
    }
    return $true
}

# The actual repair for today's fault: .NET's X509Chain follows AIA and pulls
# the missing intermediate, which we then hand to openconnect via --cafile.
# Intermediate-based, so it keeps working when the leaf is renewed.
function Update-CaBundle {
    Write-Log 'rebuilding CA bundle from server chain (AIA)...'
    $leaf = Get-ServerLeaf
    if (-not (Test-LeafIdentity $leaf)) { Write-Log 'refusing to bundle an unrecognised cert' 'ERROR'; return $false }
    try {
        $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
        $chain.ChainPolicy.RevocationMode = 'NoCheck'
        if (-not $chain.Build($leaf)) {
            foreach ($s in $chain.ChainStatus) { Write-Log "  chain status: $($s.Status)" 'WARN' }
        }
        if ($chain.ChainElements.Count -lt 2) {
            Write-Log 'no intermediate obtainable (AIA fetch failed)' 'ERROR'; return $false
        }
        $pem = ''
        for ($i = 1; $i -lt $chain.ChainElements.Count; $i++) {
            $c = $chain.ChainElements[$i].Certificate
            $b64 = [Convert]::ToBase64String($c.RawData, 'InsertLineBreaks')
            $pem += "# $($c.Subject)`r`n-----BEGIN CERTIFICATE-----`r`n$b64`r`n-----END CERTIFICATE-----`r`n"
            Write-Log "  bundled: $($c.Subject)"
        }
        Set-Content -Path $Cfg.CaBundle -Value $pem -Encoding ascii
        Write-Log "CA bundle written -> $($Cfg.CaBundle)" 'OK'
        return $true
    } catch {
        Write-Log "CA bundle rebuild failed: $($_.Exception.Message)" 'ERROR'; return $false
    }
}

# Last-resort trust path for when the chain is broken *and* AIA is blocked.
# openconnect prints the pin it would accept; we only store it after
# independently confirming the leaf's identity above.
function Save-PinFromOutput {
    param([string]$Output)
    $m = [regex]::Match($Output, 'pin-sha256:([A-Za-z0-9+/=]+)')
    if (-not $m.Success) { return $false }
    $pin = $m.Groups[1].Value
    if (-not (Test-LeafIdentity (Get-ServerLeaf))) {
        Write-Log 'not pinning: server identity failed verification' 'ERROR'; return $false
    }
    Set-Content -Path $Cfg.PinFile -Value "pin-sha256:$pin" -Encoding ascii
    Write-Log "pinned server cert (identity verified): pin-sha256:$($pin.Substring(0, 12))..." 'OK'
    return $true
}

# ---------------------------------------------------------- pre-flight
# Cheap local checks first, so a down Wi-Fi never costs a gateway attempt.
# Also distinguishes "gateway is blocking us" from "we have no network",
# because those need opposite responses.
function Test-Preflight {
    # A tunnel adapter that is up while we are between sessions means an
    # orphaned openconnect from an earlier run still holds it. This matters for
    # more than tidiness: the gateway is handed to us as a /32 split route
    # THROUGH the tunnel, so the reachability probe further down would fail and
    # get misread as "the gateway is blocking us" -- a 15 minute cooldown for
    # nothing. Observed live on 2026-08-04 during the move to the portable
    # layout, when the task was replaced while a tunnel was still up.
    $stale = @(Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'wintun|TAP|OpenConnect' -and $_.Status -eq 'Up' })
    if ($stale.Count) {
        return @{ Ok = $false; Class = 'STALETUN'
                  Reason = "orphaned tunnel adapter '$($stale[0].Name)' still up from a previous run" }
    }

    if (-not (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)) {
        return @{ Ok = $false; Class = 'NONET'; Reason = 'no default route (network down)' }
    }
    try { $null = [Net.Dns]::GetHostAddresses($Cfg.ServerHost) }
    catch { return @{ Ok = $false; Class = 'NONET'; Reason = 'DNS resolution failed' } }

    $gwUp = $false
    $tcp = New-Object Net.Sockets.TcpClient
    try { $gwUp = $tcp.ConnectAsync($Cfg.ServerHost, $Cfg.ServerPort).Wait(6000) -and $tcp.Connected }
    catch { $gwUp = $false } finally { try { $tcp.Close() } catch { } }

    if (-not $gwUp) {
        # Is the internet fine? If so the gateway is singling us out.
        $netUp = $false
        foreach ($probe in @(@('1.1.1.1', 443), @('8.8.8.8', 53))) {
            $t = New-Object Net.Sockets.TcpClient
            try { if ($t.ConnectAsync($probe[0], $probe[1]).Wait(4000) -and $t.Connected) { $netUp = $true } }
            catch { } finally { try { $t.Close() } catch { } }
            if ($netUp) { break }
        }
        if ($netUp) {
            return @{ Ok = $false; Class = 'BLOCKED'
                      Reason = 'internet is fine but gateway is unreachable -- it is likely blocking or rate-limiting us' }
        }
        return @{ Ok = $false; Class = 'NONET'; Reason = 'gateway unreachable and internet is also down' }
    }

    $rival = Get-Process -Name surfshark, nordvpn, expressvpn, openvpn, wireguard -ErrorAction SilentlyContinue
    if ($rival) {
        $names = ($rival | Select-Object -ExpandProperty Name -Unique) -join ', '
        Write-Log "another VPN client is running ($names) -- it may hijack the default route" 'WARN'
    }
    return @{ Ok = $true; Class = 'OK'; Reason = 'ok' }
}

# ---------------------------------------------------------- credentials
function Get-VpnPassword {
    if (-not (Test-Path $Cfg.CredFile)) { return $null }
    try {
        # Strip a UTF-8 BOM and trailing newline before parsing: Windows
        # PowerShell 5.1 writes a BOM with -Encoding utf8, and ConvertTo-
        # SecureString rejects the hex string if either is present.
        $raw = ([IO.File]::ReadAllText($Cfg.CredFile)).TrimStart([char]0xFEFF).Trim()
        $sec = $raw | ConvertTo-SecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch {
        Write-Log "could not decrypt $($Cfg.CredFile): $($_.Exception.Message)" 'ERROR'
        return $null
    }
}

# ------------------------------------------------------- tunnel watchdog
# openconnect can report a live session while the tunnel black-holes traffic.
# The adapter check catches a collapsed interface; HealthProbeHost catches the
# nastier case where the interface is up but nothing crosses it.
function Test-TunnelHealth {
    $tun = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -match 'wintun|TAP|OpenConnect' -and $_.Status -eq 'Up' }
    if (-not $tun) { return @{ Healthy = $false; Reason = 'no tunnel adapter up' } }

    if ($Cfg.HealthProbeHost) {
        $t = New-Object Net.Sockets.TcpClient
        try {
            if ($t.ConnectAsync($Cfg.HealthProbeHost, $Cfg.HealthProbePort).Wait(5000) -and $t.Connected) {
                return @{ Healthy = $true; Reason = 'probe ok' }
            }
            return @{ Healthy = $false; Reason = "internal probe $($Cfg.HealthProbeHost) unreachable" }
        } catch {
            return @{ Healthy = $false; Reason = "internal probe error: $($_.Exception.Message)" }
        } finally { try { $t.Close() } catch { } }
    }
    return @{ Healthy = $true; Reason = 'adapter up' }
}

# ------------------------------------------------------ run openconnect
# Password goes over the stdin pipe, in memory. The old script used
# `cmd /c echo <pw>| openconnect`, exposing it in the process command line to
# every local process, every 3 seconds.
function Invoke-OpenConnect {
    param([string]$Password, [bool]$NoDtls = $false)

    $ocArgs = @()
    if (Test-Path $Cfg.CaBundle) { $ocArgs += "--cafile=$($Cfg.CaBundle)" }
    elseif (Test-Path $Cfg.PinFile) { $ocArgs += "--servercert=$((Get-Content $Cfg.PinFile -Raw).Trim())" }
    $ocArgs += @(
        "--protocol=$($Cfg.Protocol)"
        "--user=$($Cfg.User)"
        '--passwd-on-stdin'
        "--reconnect-timeout=$($Cfg.ReconnectTimeout)"
        '--timestamp'
    )
    if ($NoDtls) { $ocArgs += '--no-dtls'; Write-Log 'retrying with DTLS disabled (suspected flaky UDP)' 'WARN' }
    $ocArgs += $Cfg.Server

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Cfg.Exe
    $psi.Arguments = ($ocArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi

    $sb = New-Object Text.StringBuilder
    $connected = $false
    $killedBy = ''
    $healthFails = 0
    $healthChecks = 0
    $started = Get-Date
    $lastHealth = Get-Date
    $lastTick = Get-Date

    try {
        [void]$proc.Start()
        $proc.StandardInput.WriteLine($Password)
        $proc.StandardInput.Close()

        # Single-threaded pump: drain both streams, run the watchdog between
        # reads. Avoids Register-ObjectEvent, whose action blocks run in a
        # separate runspace and cannot see Write-Log or $Cfg.
        $outTask = $proc.StandardOutput.ReadLineAsync()
        $errTask = $proc.StandardError.ReadLineAsync()

        while ($true) {
            $idle = $true
            foreach ($which in 'out', 'err') {
                $task = if ($which -eq 'out') { $outTask } else { $errTask }
                if ($task -and $task.IsCompleted) {
                    $line = $task.Result
                    if ($null -eq $line) {
                        if ($which -eq 'out') { $outTask = $null } else { $errTask = $null }
                    } else {
                        $idle = $false
                        [void]$sb.Append($line).Append("`n")
                        Write-Log "  oc| $line"
                        if ($line -match 'Connected as |Connected tun|ESP session established|Session authentication will expire') {
                            if (-not $connected) { $connected = $true; Write-Log 'tunnel established' 'OK' }
                        }
                        $next = if ($which -eq 'out') { $proc.StandardOutput.ReadLineAsync() } else { $proc.StandardError.ReadLineAsync() }
                        if ($which -eq 'out') { $outTask = $next } else { $errTask = $next }
                    }
                }
            }

            if ($proc.HasExited -and -not $outTask -and -not $errTask) { break }

            # A wall-clock jump means the machine slept. The session is dead
            # (this gateway never resumes a dropped session), so redial now
            # rather than letting the health probe burn ~90s proving it.
            # Threshold 30s: a loop iteration is otherwise bounded by the 5s
            # health-probe timeout plus the 250ms idle sleep.
            $tickNow = Get-Date
            if (($tickNow - $lastTick).TotalSeconds -gt 30) {
                Write-Log ("system resumed from sleep (clock jumped {0}s) -- redialling immediately" -f `
                    [int]($tickNow - $lastTick).TotalSeconds) 'WARN'
                $killedBy = 'RESUME'
                try { $proc.Kill() } catch { }
            }
            $lastTick = $tickNow

            if ($connected -and ((Get-Date) - $lastHealth).TotalSeconds -ge $Cfg.HealthIntervalSec) {
                $lastHealth = Get-Date
                $h = Test-TunnelHealth
                if ($h.Healthy) {
                    if ($healthFails -gt 0) { Write-Log "tunnel healthy again after $healthFails failed check(s)" 'OK' }
                    $healthFails = 0
                    # Heartbeat: first check, then every 10th (~5 min). Enough to
                    # prove in hindsight that the tunnel and keepalive were alive,
                    # without flooding the log.
                    $healthChecks++
                    if ($healthChecks -eq 1 -or $healthChecks % 10 -eq 0) {
                        $mins = [int]((Get-Date) - $started).TotalMinutes
                        Write-Log "heartbeat: tunnel healthy (${mins}m up, $($h.Reason))" 'OK'
                    }
                } else {
                    $healthFails++
                    Write-Log "tunnel health check failed ($healthFails/$($Cfg.HealthFailsToKill)): $($h.Reason)" 'WARN'
                    if ($healthFails -ge $Cfg.HealthFailsToKill) {
                        Write-Log 'tunnel is up but not passing traffic -- restarting it' 'ERROR'
                        $killedBy = 'STALL'
                        try { $proc.Kill() } catch { }
                    }
                }
            }

            if ($idle) { Start-Sleep -Milliseconds 250 }
        }
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
    } catch {
        Write-Log "openconnect launch/pump error: $($_.Exception.Message)" 'ERROR'
    } finally {
        if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
        try { $proc.Dispose() } catch { }
    }

    return @{
        Output      = $sb.ToString()
        DurationSec = [int]((Get-Date) - $started).TotalSeconds
        Connected   = $connected
        KilledBy    = $killedBy
    }
}

# ------------------------------------------------- failure classification
# The old loop retried every cause identically every 3s, including causes
# where retrying is useless (cert) or actively harmful (auth, blocked).
# Note the ordering: only a *definitive* rejection counts as AUTH, so a
# flaky gateway can never trick us into abandoning good credentials.
function Get-FailureClass {
    param([hashtable]$Result)
    $o = $Result.Output

    if ($Result.KilledBy -eq 'RESUME') { return 'RESUME' }
    if ($Result.KilledBy -eq 'STALL') { return 'STALL' }

    if ($o -match 'signer not found|certificate verify failed|failed verification|Error in the certificate|certificate has expired|certificate is not yet valid') {
        return 'CERT'
    }
    # Transient server-side noise. Checked BEFORE auth so a 500/502 or a
    # malformed form is never mistaken for a bad password.
    if ($o -match 'Server returned error 5\d\d|Bad Gateway|Service Unavailable|Unexpected \d+ result|Failed to parse|Empty response|unexpected EOF|Error fetching HTTPS response') {
        return 'GWERR'
    }
    if ($o -match 'Login failed|[Aa]uthentication failed|Invalid username|invalid credential|Password authentication failed|Permission denied|access denied|credentials were rejected') {
        return 'AUTH'
    }
    if ($o -match 'Failed to open tun|wintun|Failed to set up (tun|virtual)|Cannot open .*adapter|TUNSETIFF') {
        return 'TUN'
    }
    if ($o -match 'Failed to open HTTPS connection|Failed to connect to host|Name or service not known|Network is unreachable|Connection timed out|No route to host|Connection reset') {
        return 'NET'
    }
    if ($Result.Connected) { return 'DROP' }
    return 'UNKNOWN'
}

# ---------------------------------------------------------------- main
$mutex = New-Object Threading.Mutex($false, 'Global\AutoVPN-openconnect-supervisor')
if (-not $mutex.WaitOne(0)) {
    Write-Log 'another supervisor instance is already running -- exiting' 'WARN'
    exit 0
}

# Anything that escapes the loop below is a bug, not a gateway fault. Record it
# before the script unwinds -- until 2026-09-22 a stopped supervisor left no
# trace at all, which turned a one-line scheduler misconfiguration
# (StopOnIdleEnd) into a month of "the VPN just drops sometimes".
trap {
    Write-Log "unhandled error: $($_.Exception.Message) -- $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')" 'ERROR'
    break
}

$exitNote = 'supervisor exiting (stopped externally: Task Scheduler stop, console close, or Ctrl+C)'
try {
    New-Item -ItemType Directory -Force -Path $Cfg.StateDir | Out-Null
    Write-Log ('=' * 72)
    Write-Log "AutoVPN supervisor starting (pid $PID)"

    if (-not (Test-Path $Cfg.Exe)) {
        Write-Log "openconnect not found at $($Cfg.Exe)" 'ERROR'
        Set-Halt 'openconnect binary missing'
        exit 1
    }

    $password = Get-VpnPassword
    if (-not $password) {
        Write-Log 'no stored credential. Run this once (as your own user), then start the task:' 'ERROR'
        Write-Log '  Read-Host "VPN password" -AsSecureString | ConvertFrom-SecureString |' 'ERROR'
        Write-Log "    Set-Content '$($Cfg.CredFile)'" 'ERROR'
        Set-Halt 'no stored credential'
        exit 1
    }

    if (-not (Test-Path $Cfg.CaBundle)) { [void](Update-CaBundle) }

    $delay        = $Cfg.BackoffBaseSec
    $consecFail   = 0
    $authFail     = 0
    $certAttempts = 0
    $youngRun     = 0
    $dtlsFail     = 0
    $noDtls       = $false

    while ($true) {
        $pre = Test-Preflight
        if (-not $pre.Ok) {
            if ($pre.Class -eq 'BLOCKED') {
                Write-Log "pre-flight: $($pre.Reason)" 'ERROR'
                Write-Log "cooling down $($Cfg.BlockedCooldownSec)s -- knocking while banned only extends it" 'WARN'
                Start-Sleep -Seconds $Cfg.BlockedCooldownSec
                $delay = $Cfg.BackoffBaseSec
            } elseif ($pre.Class -eq 'STALETUN') {
                # Clear the orphan and re-check at once -- this is our own mess,
                # not a reason to back off from the gateway.
                Write-Log "pre-flight: $($pre.Reason) -- clearing it" 'WARN'
                Get-Process -Name openconnect -ErrorAction SilentlyContinue |
                    ForEach-Object { try { $_.Kill() } catch { } }
                Start-Sleep -Seconds 5
            } else {
                Write-Log "pre-flight: $($pre.Reason) -- not spending a connection attempt" 'WARN'
                Start-Sleep -Seconds $delay
                $delay = [Math]::Min($delay * $Cfg.BackoffFactor, $Cfg.BackoffMaxSec)
            }
            continue
        }

        Write-Log "connecting to $($Cfg.Server) as $($Cfg.User)..."
        $r = Invoke-OpenConnect -Password $password -NoDtls $noDtls
        $class = Get-FailureClass -Result $r
        Write-Log "session ended after $($r.DurationSec)s (connected=$($r.Connected)) -- cause: $class"

        # Anything that stayed up a while proves cert + credentials are fine.
        if ($r.DurationSec -ge $Cfg.HealthySec) {
            $delay = $Cfg.BackoffBaseSec
            $consecFail = 0; $authFail = 0; $certAttempts = 0
            Clear-Halt
        }

        # This gateway's DTLS/UDP path fails on some networks; openconnect then
        # burns ~5s per connect before falling back to HTTPS. Once we've seen
        # it fail twice, stop asking for it. Kept adaptive rather than hardcoded
        # so DTLS is still used on networks where UDP does work.
        if (-not $noDtls -and $r.Output -match 'Failed to connect DTLS tunnel') {
            $dtlsFail++
            if ($dtlsFail -ge 2) {
                Write-Log 'DTLS keeps failing -- skipping it from now on (saves ~5s per connect)' 'WARN'
                $noDtls = $true
            }
        }

        # Repeated short-lived sessions point at the transport, not at auth.
        if ($r.Connected -and $r.DurationSec -lt $Cfg.YoungSessionSec) {
            $youngRun++
            if ($youngRun -ge $Cfg.YoungBeforeNoDtls -and -not $noDtls) {
                Write-Log "$youngRun short sessions in a row -- disabling DTLS for subsequent attempts" 'WARN'
                $noDtls = $true; $youngRun = 0
            }
        } elseif ($r.DurationSec -ge $Cfg.HealthySec) {
            $youngRun = 0
        }

        switch ($class) {
            'AUTH' {
                $authFail++
                Write-Log "AUTHENTICATION REJECTED ($authFail/$($Cfg.MaxAuthFailures))" 'ERROR'
                if ($authFail -ge $Cfg.MaxAuthFailures) {
                    Write-Log 'giving up: refusing to retry rejected credentials and risk an account lockout.' 'ERROR'
                    Write-Log 'update the stored password, then restart the task.' 'ERROR'
                    Set-Halt 'credentials rejected by gateway'
                    exit 2
                }
                $delay = 60
            }
            'CERT' {
                $certAttempts++
                Write-Log "certificate verification failed (repair attempt $certAttempts)" 'ERROR'
                if ($certAttempts -eq 1) {
                    # Most likely today's fault: gateway dropped the intermediate.
                    if (Update-CaBundle) { $delay = 5; break }
                } elseif ($certAttempts -eq 2) {
                    # AIA unavailable too -> identity-checked pin as a fallback.
                    Write-Log 'CA bundle route failed; trying identity-verified pinning' 'WARN'
                    Remove-Item $Cfg.CaBundle -Force -ErrorAction SilentlyContinue
                    if (Save-PinFromOutput -Output $r.Output) { $delay = 5; break }
                }
                Write-Log 'cert still unverifiable -- this needs a server-side fix (full chain on the gateway).' 'ERROR'
                $consecFail++
                $delay = $Cfg.BackoffMaxSec
            }
            'GWERR' {
                Write-Log 'gateway returned a transient server-side error -- retrying (credentials untouched)' 'WARN'
                $consecFail++
                $delay = [Math]::Min([Math]::Max($delay, 30) * $Cfg.BackoffFactor, $Cfg.BackoffMaxSec)
            }
            'STALL' {
                Write-Log 'reconnecting after a stalled tunnel' 'WARN'
                Get-Process -Name openconnect -ErrorAction SilentlyContinue |
                    ForEach-Object { try { $_.Kill() } catch { } }
                $delay = 10
            }
            'RESUME' {
                # Not a fault of ours or the gateway's -- redial as fast as the
                # network allows. Pre-flight still gates the attempt, so a
                # Wi-Fi that hasn't reassociated yet just means a short wait.
                Write-Log 'redialling after system resume' 'WARN'
                Get-Process -Name openconnect -ErrorAction SilentlyContinue |
                    ForEach-Object { try { $_.Kill() } catch { } }
                $delay = 2
            }
            'TUN' {
                Write-Log 'virtual adapter problem -- clearing stray openconnect processes' 'WARN'
                Get-Process -Name openconnect -ErrorAction SilentlyContinue |
                    ForEach-Object { try { $_.Kill() } catch { } }
                $consecFail++
                $delay = 15
            }
            'NET' {
                $consecFail++
                $delay = [Math]::Min($delay * $Cfg.BackoffFactor, $Cfg.BackoffMaxSec)
            }
            'DROP' {
                Write-Log 'tunnel dropped after a healthy session -- reconnecting shortly' 'WARN'
                $delay = $Cfg.BackoffBaseSec
            }
            default {
                $consecFail++
                $delay = [Math]::Min($delay * $Cfg.BackoffFactor, $Cfg.BackoffMaxSec)
            }
        }

        if ($consecFail -ge $Cfg.BreakerThreshold) {
            Write-Log "circuit breaker: $consecFail consecutive failures -- sleeping $($Cfg.BreakerSleepSec)s" 'ERROR'
            Start-Sleep -Seconds $Cfg.BreakerSleepSec
            $consecFail = 0
            $certAttempts = 0
            $delay = $Cfg.BackoffBaseSec
            continue
        }

        # Jitter, so repeated failures never line up into a steady pulse that
        # looks like an attack to the gateway.
        $j = 1 + ((Get-Random -Minimum (-$Cfg.JitterPct) -Maximum $Cfg.JitterPct) / 100.0)
        $sleep = [Math]::Max(1, [int]($delay * $j))
        Write-Log "next attempt in ${sleep}s"
        Start-Sleep -Seconds $sleep
    }
} finally {
    # Reached on `exit`, on an unhandled error (after the trap above) and when
    # the pipeline is stopped from outside (scheduler stop / console close), so
    # the log always says how a run ended. Not reached on a hard kill.
    Write-Log $exitNote 'WARN'
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}

# AutoVPN — moreh VPN 자동 연결

openconnect 기반 moreh VPN 자동 연결/자동 복구 세트.
2026-08-03 장애 조사 결과물이며, 조사 기록은 [§7 장애 분석](#7-장애-분석-2026-08-03)에 있다.
2026-09-22에 "절전에서 깨어나면 VPN이 끊겨 있는" 문제를 고쳤다 ([§9](#9-구현-중-발견한-함정)의 `StopOnIdleEnd`).

```
로그온 / 절전 해제 / 잠금 해제 → 자동 연결 → 끊기면 자동 재연결 → supervisor가 죽으면 watchdog이 1분 안에 부활
```

---

## 1. 설치

레포를 clone 하거나 이 `autovpn\` 폴더만 복사해서, 그 안에서:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

UAC 한 번 승인하면 끝난다. scheduled task는 **`install.ps1`을 실행한 위치의 스크립트를 가리킨다.**
그러니 폴더를 옮기면 `install.ps1`을 다시 돌려야 한다. 하는 일:

1. openconnect 위치 자동 탐지
2. `AutoVPN` 태스크 등록 — 로그온 +30초 / 절전 해제 +15초 / 잠금 해제 +5초, 관리자 권한, 네트워크 대기
3. `AutoVPN-Watchdog` 태스크 등록 — 1분마다 supervisor 생존 확인
4. Task Scheduler history log 켜기 (누가 태스크를 멈췄는지 남기려고)
5. VPN 비밀번호 입력받아 DPAPI 암호화 저장 (UAC 창이 아니라 원래 사용자 권한으로)
6. 연결 시작

### 사전 조건

**OpenConnect-GUI**가 설치돼 있어야 한다 (openconnect.exe + wintun.dll 포함).
→ https://github.com/openconnect/openconnect-gui/releases

탐지 경로 (`Find-OpenConnect`):
```
%ProgramFiles%\OpenConnect-GUI\openconnect.exe
%ProgramFiles(x86)%\OpenConnect-GUI\openconnect.exe
%LOCALAPPDATA%\Programs\OpenConnect-GUI\openconnect.exe
%ProgramFiles%\OpenConnect\openconnect.exe
PATH 상의 openconnect.exe
```

### 복사하면 안 되는 것

| 항목 | 이유 |
|---|---|
| `cred.dpapi` | DPAPI가 **사용자+장비**에 바인딩. 다른 PC에서 복호화 불가 → 새 PC에서 `install.ps1` 재실행 |
| `moreh-chain.pem` | 자동 재생성됨 |
| `autovpn.log` | 로그 |

셋 다 레포가 아니라 `%LOCALAPPDATA%\AutoVPN\`에 생기므로, 이 폴더만 옮기면 된다.
`%LOCALAPPDATA%\AutoVPN\`은 복사하지 않는다.

### 제거

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1            # 태스크 + 상태 삭제
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -KeepState # 태스크만 삭제
```

---

## 2. 구성

```
my_configs\autovpn\                ← 복사 대상 (포터블, 어디 둬도 됨)
  install.ps1        설치 (자동 권한 상승)
  uninstall.ps1      제거
  vpn-auto.ps1       supervisor 본체
  watchdog.ps1       supervisor 생존 감시
  setup-cred.ps1     비밀번호 저장/변경
  README.md          이 문서

%LOCALAPPDATA%\AutoVPN\            ← 런타임 상태 (PC 고유, 복사 금지)
  cred.dpapi         DPAPI 암호화 비번, ACL 잠금
  moreh-chain.pem    CA 번들 — 자동 생성/갱신
  servercert.pin     pin 폴백 (사용될 때만)
  halt.reason        의도적 정지 플래그 (§4.5)
  autovpn.log        supervisor 로그, 5MB × 3 로테이션
  watchdog.log       watchdog 로그, 1MB × 2
```

### 스케줄 태스크

| | `AutoVPN` | `AutoVPN-Watchdog` |
|---|---|---|
| 실행 | `vpn-auto.ps1` | `watchdog.ps1` |
| 트리거 | 로그온 +30초 / 절전 해제(Power-Troubleshooter event 1) +15초 / 잠금 해제 +5초 | 1분마다 (10년) |
| 권한 | **Highest** (wintun·라우팅), Interactive | Limited, **S4U** (창 안 뜸) |
| `RunOnlyIfNetworkAvailable` | True | — |
| `StopOnIdleEnd` | **False (필수, §9)** | False |
| `ExecutionTimeLimit` | 무제한 | 5분 |
| 배터리 | 시작 허용 / 유지 | 시작 허용 / 유지 |
| `RestartCount` | **0 (의도적)** | — |

> `RestartCount = 0`인 이유: supervisor는 **재시도하지 않기로 결정한 경우에만** non-zero로 종료한다(특히 비번 거부). 스케줄러 자동 재시작은 그 방어를 무력화한다. 크래시 복구는 halt 플래그를 존중하는 watchdog이 담당한다.
>
> 트리거가 중복으로 떠도(절전 해제 직후 잠금 해제) 무해하다. 태스크는 `IgnoreNew`이고 supervisor는 global mutex를 잡는다.

---

## 3. 설정값

`vpn-auto.ps1` 상단 `$Cfg`:

| 키 | 값 | 비고 |
|---|---|---|
| `Server` / `User` | `vpn.moreh.dev:20022` / `jungwook` | |
| `Protocol` | `fortinet` | |
| `HealthProbeHost` | `10.40.10.50:22` | 내부 호스트. **watchdog + keepalive 겸용** |
| `HealthIntervalSec` | 30 | 유휴 타임아웃(60분) 방지 |
| `HealthFailsToKill` | 3 | 3회 연속 실패 → 터널 재시작 |
| `BackoffBaseSec` / `Max` | 10 / 600 | 지터 ±20% |
| `HealthySec` | 60 | 이 이상 유지되면 "정상"으로 보고 카운터 리셋 |
| `BreakerThreshold` / `Sleep` | 5 / 1800 | 연속 실패 5회 → 30분 정지 |
| `BlockedCooldownSec` | 900 | 게이트웨이 차단 감지 시 |
| `MaxAuthFailures` | 2 | 초과 시 완전 정지 |

---

## 4. 동작

### 4.1 원인별 대응

구 스크립트는 **모든 실패에 똑같이 3초 재시도**를 했다. 재시도가 무용한 경우와 **해로운 경우**를 구분하지 못한 것이 장애의 본질이었다.

| 분류 | 트리거 | 대응 |
|---|---|---|
| `CERT` | `signer not found` 등 | ① AIA로 CA 번들 재생성 → 즉시 재시도 ② 실패 시 **신원 검증된** pin 폴백 ③ 그래도 실패면 최대 백오프 |
| `AUTH` | `Login failed`, `Invalid username` | **2회에서 완전 정지** + halt 플래그. 계정 잠김 방어 |
| `GWERR` | 5xx, `Bad Gateway`, 응답 파싱 실패 | 재시도. **AUTH로 오판하지 않음** (분류 순서상 AUTH보다 먼저) |
| `BLOCKED` | 게이트웨이만 무응답 + 인터넷 정상 | 15분 냉각. 차단 중 노크는 차단을 연장시킨다 |
| `STALETUN` | 터널 어댑터가 남아 있음 | 고아 정리 후 **즉시** 재시도 (백오프 없음) |
| `NONET` | default route 없음 / DNS 실패 | 접속 시도를 소비하지 않고 백오프 |
| `TUN` | wintun 어댑터 문제 | 잔류 프로세스 정리 후 15초 |
| `STALL` | watchdog이 죽인 경우 | 즉시 재연결 |
| `RESUME` | 절전 해제 감지 (pump loop의 wall-clock이 30초 넘게 점프) | 죽은 세션 kill 후 **2초 뒤** 재연결. health probe 3회 실패(~90초)를 기다리지 않는다 |
| `NET` | 연결 도중 `Connection timed out` 등 | 백오프 |
| `DROP` | 정상 세션 후 끊김 | 짧은 지연 후 재연결 |

### 4.2 인증서 자가 복구

```
Update-CaBundle():
  서버 leaf 직접 fetch
    → Test-LeafIdentity : CN=*.moreh.dev / issuer=Sectigo / 유효기간 검사
    → .NET X509Chain.Build()   ← AIA를 따라감 (GnuTLS가 못 하는 부분)
    → chain[1..n] (CA만) PEM 저장 → --cafile
```

**중간 인증서 기반**이라 leaf가 갱신돼도 안 깨진다 (중간 인증서는 2036-03-22까지 유효).

pin 폴백은 `Test-LeafIdentity` 통과 후에만 저장한다 — 체인 파손을 "아무거나 신뢰"로 바꾸지 않는다.

### 4.3 터널 watchdog + keepalive

30초마다 `10.40.10.50:22` 접속 확인.

- 어댑터 up 여부만 보면 **"연결됐는데 통신 안 되는"** 블랙홀 터널을 못 잡는다 → 실제 내부 호스트로 probe
- 3회 연속 실패 → openconnect kill → 재연결
- **이 probe가 keepalive 역할도 한다** → 게이트웨이 유휴 60분 타임아웃 원천 차단
- heartbeat: 첫 성공 + 이후 10회마다(~5분) 로그 기록

### 4.4 재시작 계층

| 죽는 대상 | 복구 주체 |
|---|---|
| openconnect | supervisor의 `while ($true)` |
| 터널 (up이지만 불통) | supervisor의 health watchdog |
| **supervisor 자체** | **`AutoVPN-Watchdog` 태스크 (1분 주기)** |
| 절전 → 해제 | supervisor가 살아 있으면 `RESUME` 감지, 죽었으면 절전 해제/잠금 해제 트리거 |
| 로그오프/재부팅 | 로그온 트리거 |

### 4.5 halt 플래그

"죽으면 되살린다"가 "거부된 비번을 영원히 재시도한다"로 변질되는 것을 막는 장치.

```
supervisor가 의도적으로 포기 → halt.reason 기록
  · 비번 거부 (exit 2)
  · 자격증명 없음 (exit 1)
  · openconnect 바이너리 없음 (exit 1)

watchdog: halt.reason 있으면 → 재시작 거부 (로그만 남김)
해제 조건: 정상 세션(60초+) 확인 시 자동 / setup-cred.ps1 실행 시 / install.ps1 실행 시
```

수동 `Start-ScheduledTask`는 halt와 무관하게 항상 동작한다.

---

## 5. 운영

```powershell
# 상태
Get-ScheduledTask AutoVPN, AutoVPN-Watchdog | Select TaskName, State
Get-NetIPAddress -InterfaceAlias 'vpn.moreh.dev' -AddressFamily IPv4

# 로그
Get-Content "$env:LOCALAPPDATA\AutoVPN\autovpn.log"  -Tail 40 -Wait
Get-Content "$env:LOCALAPPDATA\AutoVPN\watchdog.log" -Tail 20

# 재시작
Stop-ScheduledTask AutoVPN; Start-ScheduledTask AutoVPN

# 비번 변경 (halt 플래그도 자동 해제)
powershell -ExecutionPolicy Bypass -File .\setup-cred.ps1

# 태스크만 재등록 (비번 유지)
powershell -ExecutionPolicy Bypass -File .\install.ps1 -SkipCredential
```

### 로그 읽기

`session ended after Ns -- cause: XXX` 줄의 분류만 보면 원인이 나온다.

| 분류 | 조치 |
|---|---|
| `CERT` | 자동 복구 시도됨. 계속 나오면 게이트웨이 체인 문제 → IT 요청 (§7.1) |
| `AUTH` | 비번 오류. `setup-cred.ps1` 재실행 |
| `BLOCKED` | 차단 중. **아무것도 하지 말고 기다린다** |
| `GWERR` | 게이트웨이 일시 오류. 자동 재시도됨 |
| `STALETUN` | 고아 터널. 자동 정리됨 |
| `STALL` | 블랙홀 감지 → 자동 재연결됨 |
| `RESUME` | 절전 해제 → 자동 재연결됨. 정상 |
| `TUN` | 어댑터 충돌. 다른 VPN(§6) 확인 |

로그에 **`supervisor exiting (stopped externally ...)`**가 찍혔으면 누군가 태스크를 멈춘 것이다.
누가 멈췄는지는 Task Scheduler history에 남는다 (`install.ps1`이 켜둔다):

```powershell
Get-WinEvent -LogName Microsoft-Windows-TaskScheduler/Operational -MaxEvents 50 |
  Where-Object Message -match 'AutoVPN' | Select TimeCreated, Id, Message
```

정상 상태: `heartbeat: tunnel healthy (Nm up, probe ok)`가 ~5분마다.

---

## 6. 알려진 제약

### split-DNS 미동작
openconnect가 split-DNS를 구현하지 않아 **`*.moreh.internal` 호스트명 해석이 안 된다**. IP로는 접근 가능. 게이트웨이는 `moreh.internal` 도메인과 DNS `1.249.213.155`를 내려주지만 openconnect가 `not yet implemented` 경고만 낸다.
→ 필요하면 터널 어댑터에 DNS 수동 지정 또는 hosts 등록. (터널 끊길 때 해석 실패 위험이 있어 기본 적용하지 않았다.)

### 다른 full-tunnel VPN과 충돌
Surfshark 등이 연결되면 default route를 가져가 moreh 터널을 깨뜨린다. supervisor가 경고 로그는 남기지만 막지는 못한다. **동시 사용 회피.**

### 16시간 세션 만료
게이트웨이가 세션 인증을 ~16시간으로 제한한다. 만료 시 재인증이 필요하며 supervisor가 재연결로 처리한다. (실측 미확인 — §8)

### wintun 실험적
openconnect가 `Support for Wintun is experimental` 경고를 낸다. 불안정하면 TAP-Windows 드라이버 대안이 있다.

---

## 7. 장애 분석 (2026-08-03)

### 7.1 원인: 게이트웨이가 중간 인증서를 안 보낸다

```
$ openssl s_client -connect vpn.moreh.dev:20022 -showcerts
BEGIN CERTIFICATE 개수: 1          ← leaf 하나뿐
subject = CN = *.moreh.dev, O = MOREH Corp., S = Seoul, C = KR
issuer  = CN = Sectigo Public Server Authentication CA OV R36   ← 이걸 안 보냄
Verify return code: 21 (unable to verify the first certificate)
```

`21`은 openssl에서 **중간 인증서 누락 전용** 코드다.

openconnect 실패:
```
Server certificate verify failed: signer not found
SSL connection failure: Error in the certificate.
Failed to complete authentication
```

**통제 실험** — 동일 바이너리로 기준점 2개:

| 대상 | 체인 | 결과 |
|---|---|---|
| `sha256.badssl.com:443` | 완전 | **검증 성공** (`Connected to HTTPS ... TLS1.2`) |
| `incomplete-chain.badssl.com:443` | 중간 누락 | `signer not found` — **moreh 에러와 글자까지 동일** |

→ CA 저장소 문제가 아니다. openconnect는 Windows 루트 저장소를 정상적으로 읽는다.
→ **서버가 보내는 체인이 불완전**한 것.

**왜 브라우저는 되나**: `.NET`/schannel/브라우저는 leaf의 **AIA** 확장으로 중간 인증서를 자동 다운로드한다. GnuTLS는 하지 않는다. (증거: 중간 인증서가 `Cert:\CurrentUser\CA`에 캐시돼 있었다 = AIA fetch 흔적)
→ **openconnect·curl 등 GnuTLS/OpenSSL 클라이언트만 전부 깨지고** 브라우저는 멀쩡해 보이는 상태.

**서버 인증서**: `CN=*.moreh.dev` / Sectigo OV / 2026-07-28 ~ 2027-02-12 / pin `kg7S+XZJzVdpO6QWTv8N2QcpM+k4b9MEuFmkKkBYboM=`
발급일이 2026-07-28이고 "어제까지 됐다"는 증언과 맞물려, 게이트웨이에 중간 인증서 없이 leaf만 재설치된 시점이 2026-08-03으로 추정된다.

> **미완 조치**: moreh IT에 **FortiGate full chain 등록** 요청. 현재는 클라이언트 우회 중이고, 같은 도구를 쓰는 다른 동료도 동일 증상을 겪는다. 서버가 정상화되면 `moreh-chain.pem`은 무해하게 남는다.

### 7.2 3초 루프가 장애를 IP 차단으로 증폭

구 `vpn-auto.vbs`:
```vbs
Do
    objShell.Run "cmd.exe /c echo <비번>| ""...\openconnect.exe"" ...", 0, True
    WScript.Sleep 3000
Loop
```

```
wscript 실행 43분 / 누적 CPU 13.6초 / 살아있는 openconnect 0개
→ 약 860회 접속 시도
```

결과:
```
23:31  vpn.moreh.dev:20022   TcpTestSucceeded : True   ← 잘 붙던 상태
23:40  6회 연속 TIMEOUT                                ← 완전 무응답
       대조군 1.1.1.1 / 8.8.8.8 / github.com / moreh.io 전부 정상
```

**루프 정지 직후 차단 해제** — 인과 확인. 차단이 주기적으로 걸렸다 풀렸다 하면서 "가끔 되고 자꾸 끊긴다"로 나타났다.

인증서 검증이 **인증 단계 이전**에 실패하므로 860회는 전부 auth 도달 전 종료였다 → 계정 잠김 위험은 없었다.

### 7.3 게이트웨이 특성 (연결 성공 후 확인)

| 항목 | 값 | 설계에 준 영향 |
|---|---|---|
| `reconnect-after-drop` | **not allowed** | openconnect가 **스스로 재연결 못 함**. `--reconnect-timeout`이 무의미하고 **외부 supervisor 루프가 유일한 재연결 수단** |
| `Idle timeout` | **60분** | 재연결 불가라 유휴 드롭이 full re-auth가 된다 → **keepalive 필수** |
| Session auth 만료 | 약 **16시간** | |
| DTLS | **실패**, HTTPS 폴백 | 매 접속 ~5초 낭비 → 2회 실패 후 `--no-dtls` 자동 전환 |
| split-DNS | `moreh.internal` **미구현** | §6 |
| 할당 IP | `192.168.60.x/32` | |
| 어댑터 | wintun, desc `OpenConnect Tunnel` | watchdog 필터가 반드시 `OpenConnect`를 포함해야 함 |

split routes (full tunnel 아님):
```
10.40.10.50/32     ← SSH(22) ~10ms → health probe 대상
1.249.213.155/32   ← 게이트웨이 자신 (§9의 STALETUN 버그 원인)
10.168.0.0/16
192.168.0.0/18
192.168.212.0/24
```

**"자꾸 끊어짐"은 두 겹이었다**: (1) IP 차단 사이클, (2) 유휴 60분 + 자체 재연결 불가. 둘 다 조치됨.

---

## 8. 검증 기록

### 검증됨 (2026-08-04)

```
syntax                     5개 스크립트 전부 CLEAN (AST parse)
분류기 단위 테스트          8/8 PASS (실제 openconnect 출력 기반)
  502 Bad Gateway   -> GWERR   (AUTH 오판 없음)
  응답 파싱 실패     -> GWERR   (AUTH 오판 없음)
  실제 비번 오류     -> AUTH
  signer not found  -> CERT
Update-CaBundle            OK (중간+루트 번들 생성)
Test-Preflight             OK (타 VPN 경고 정상 발생)
--cafile 적용 후 접속       Connected to HTTPS (TLS1.3) / Username:
자격증명 왕복 복호화        OK (8 chars)
openconnect 자동 탐지       OK
watchdog: supervisor 정상   PASS (완전 무음)
STALETUN 수정              PASS — 같은 로그에 before/after:
    00:32:58  cooling down 900s               ← 버그
    00:34:37  orphaned tunnel ... clearing it  ← 수정
    00:34:48  tunnel established              ← 11초 복구
실제 연결                  tunnel IP 192.168.60.x, split route 5개,
                           10.40.10.50:22 도달, heartbeat 정상
태스크 마이그레이션         양쪽 태스크가 Documents\AutoVPN\ 참조 확인
```

### 미검증

정직하게 남긴다. 실제 발생 시 로그로 확인해야 한다.

- **watchdog의 실제 부활 동작** — supervisor는 권한 상승 프로세스라 비상승 셸에서 강제 종료 불가. 정상 시 무음(PASS)만 확인, 크래시 시 재시작 경로는 미실측
- **16시간 세션 만료 후 재인증**
- **circuit breaker 30분 정지** 실동작
- **pin 폴백 경로** (AIA까지 막힌 상황)
- **`AUTH` 정지 경로** — 계정 잠김 위험 때문에 의도적으로 미테스트

---

## 9. 구현 중 발견한 함정

같은 실수를 반복하지 않기 위한 기록.

| 함정 | 내용 |
|---|---|
| **게이트웨이가 터널 안에 있다** | `1.249.213.155/32`가 split route로 들어와, 터널이 살아있으면 게이트웨이 직접 TCP 검사가 실패한다. 이걸 "차단당함"으로 오진해 **15분씩 날렸다**. → `STALETUN` 분류 추가 (§4.1). 실동작에서 발견. |
| **PS 5.1 BOM** | `Set-Content -Encoding utf8`이 **5.1에서는 BOM을 붙인다**. `ConvertTo-SecureString`이 hex 파싱 실패(`입력 문자열의 형식이 잘못되었습니다`). 태스크는 `powershell.exe`(5.1)로 도니 no-BOM 쓰기 + BOM/공백 제거 읽기가 필수. pwsh 7은 BOM을 안 붙여서 테스트에서 안 잡혔다. |
| **StrictMode 미초기화** | `$dtlsFail`을 초기화 없이 사용 → 예외. |
| **태스크 수정 권한** | `RunLevel Highest` 태스크는 `Set-ScheduledTask`에 권한 상승 필요. 비상승 셸에서는 **non-terminating 에러라 `try/catch`에 안 걸리고 조용히 실패**한다 (성공한 것처럼 보였다). |
| **배터리 기본값** | `New-ScheduledTaskSettingsSet` 기본값이 "배터리면 시작 안 함 / 배터리 되면 중지". 노트북에서 그대로 두면 **또 랜덤하게 끊기는 것처럼** 보인다. |
| **`StopOnIdleEnd`** | `New-ScheduledTaskSettingsSet`이 **말없이 `StopOnIdleEnd=true`**("컴퓨터가 유휴 상태를 벗어나면 중지")를 넣는다. idle 트리거가 아니어도 **실행 중인 모든 인스턴스**에 적용된다. modern standby는 완벽한 idle이라, 절전에서 돌아오는 순간 스케줄러가 supervisor를 조용히 죽였다 — 로그 없음, 터널 없음, watchdog이 알아챌 때까지 VPN 없음. 2026-08-19 ~ 09-22 **매 절전 해제마다** 발생. → `-DontStopOnIdleEnd` 필수 + supervisor에 exit 로그(`finally`)와 `trap` 추가 |
| **로그온 트리거만으론 부족** | 절전 해제는 로그온 이벤트를 안 낸다. 로그온 트리거만 있으면 watchdog 다음 차례까지 아무도 재연결하지 않는다 (2026-08-18: 21:28 기상, 21:35에야 복구). → Power-Troubleshooter event 1 트리거 + 잠금 해제 트리거 추가 |
| **Interactive 태스크 창 깜빡임** | Interactive로 도는 `powershell.exe` 태스크는 `-WindowStyle Hidden`이어도 **매번 콘솔 창이 번쩍인다** (PowerShell이 숨기기 전에 콘솔이 먼저 만들어짐). 1분마다 도는 watchdog에선 치명적. → watchdog은 S4U(session 0)로. UI도 DPAPI도 필요 없어서 가능 |
| **`Register-ObjectEvent`** | action 블록이 **별도 runspace**에서 실행되어 `Write-Log`·`$Cfg`가 안 보인다. `ReadLineAsync()` 폴링 루프로 대체 (watchdog을 같은 루프에서 돌릴 수 있어 결과적으로 더 낫다). |
| **어댑터 이름** | wintun 어댑터의 `InterfaceDescription`은 `OpenConnect Tunnel`이다 — **`wintun` 문자열이 없다.** 필터에 `OpenConnect` 필수. |
| **권한 상승 프로세스 조회** | 비상승 셸에서는 `Get-CimInstance Win32_Process`로 상승 프로세스의 `CommandLine`을 못 읽는다 (조용히 빈 결과). |
| **IDE stale 진단** | PSScriptAnalyzer가 구 버전 기준 `$args` 경고를 계속 표시했다. 실제 파일엔 0건. 파일 재생성 후 사라짐. |

---

## 10. 보안 메모

- 구 `vpn-auto.vbs`는 비번을 **평문 저장** + `cmd /c echo <비번>|` 방식으로 **3초마다 프로세스 커맨드라인에 노출**시켰다 (로컬 아무 프로세스나 WMI로 조회 가능).
- 현재: DPAPI(사용자+장비 바인딩) + 파일 ACL 단독 권한 + **stdin 파이프로 메모리 전달**.
- 구 비번은 ① 평문 파일 ② 커맨드라인 ③ 조사 중 채팅 공유로 3중 노출됐다 → **교체 권장**. 교체 후 `setup-cred.ps1` 재실행.
- `Documents\vpn-auto.vbs`(구 스크립트, 평문 비번)는 삭제됐다 (2026-09-30 확인).
- pin 폴백은 신원 검증(CN/issuer/유효기간) 통과 시에만 저장 — 체인 파손을 "아무거나 신뢰"로 바꾸지 않는다.

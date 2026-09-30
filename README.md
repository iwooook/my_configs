# my_configs

개인 서버·PC 설정 모음. 새 머신을 받으면 clone 해서 필요한 것만 적용한다.

```bash
git clone https://github.com/iwooook/my_configs.git ~/my_configs
```

| 구성 | 대상 | 하는 일 | 진입점 |
|------|------|---------|--------|
| [원격 접속 상시화](#원격-접속-상시화-claude-rc--vs-code-tunnel) | Linux 서버 | `claude rc` + VS Code tunnel을 리붓·크래시와 무관하게 항상 띄워둠 | `setup-remote-access.sh` |
| [Ctrl+G → VS Code](#claude-code-ctrlg--vs-code-tmux-안에서) | Linux 서버 (tmux) | Claude Code의 Ctrl+G가 **지금 보고 있는** VS Code 창에 열리게 | `code-wait` |
| [AutoVPN](#autovpn-windows) | Windows PC | moreh VPN을 scheduled task로 자동 연결·자동 복구 | `autovpn\install.ps1` |
| [dotfiles](#dotfiles) | 어디든 | `.vimrc`, `.tmux.conf`, `logid.cfg` | 직접 복사 |

```
my_configs/
├── setup-remote-access.sh      원격 접속 상시화 설치 스크립트
├── remote-access-common.sh     └ 공용 함수
├── tmux-server-up.sh           └ launcher 3개 (~/.local/bin에 symlink됨)
├── start-claude-rc.sh
├── start-vscode-tunnel.sh
├── *.service                   └ systemd user unit 3개
├── code-wait                   Ctrl+G용 $EDITOR
├── autovpn/                    Windows VPN 자동 연결 (자세한 문서: autovpn/README.md)
└── .vimrc  .tmux.conf  logid.cfg
```

Linux 쪽 파일이 루트에 흩어져 있는 건 의도적이다. 이미 설치된 서버들의 `~/.local/bin`
symlink가 `~/my_configs/<파일>`을 가리키고 있어서, 옮기면 그 서버들이 깨진다.

---

## 원격 접속 상시화 (claude rc + VS Code tunnel)

리붓·크래시와 무관하게 **밖에서 항상 붙을 수 있는 상태**를 만든다. tmux 기본 소켓의
세션 두 개로 돌아가고, systemd `--user`가 부팅 때 띄운다.

| 세션 | 하는 일 | 밖에서 접속 |
|------|---------|-------------|
| `claude-rc` | `claude rc` | claude.ai/code + 모바일 앱 |
| `vscode-tunnel` | `code tunnel` | `https://vscode.dev/tunnel/<호스트명>` |

### 1. 설치

```bash
~/my_configs/setup-remote-access.sh --check   # 뭐가 없는지만 확인 (아무것도 안 바꿈)
~/my_configs/setup-remote-access.sh           # 실제 설치
```

여러 번 돌려도 안전하다. 이미 떠 있는 세션은 건드리지 않는다 (`start`만 쓰고
`restart`는 안 쓴다).

하는 일: launcher를 `~/.local/bin`에 symlink → unit 3개를 `~/.config/systemd/user`에
설치 → `loginctl enable-linger` (로그인 안 해도 부팅 때 뜨게) → enable + start.
VS Code CLI가 없으면 받아서 `~/.local/bin/code`에 넣는다. symlink라서 이후엔
`git pull`만 해도 launcher가 갱신된다.

옵션: `--no-tunnel`, `--no-claude-rc`, `--no-download`, `--name <터널이름>`,
`--workdir <경로>`

### 2. 호스트마다 한 번: 로그인

둘 다 계정 인증이 홈 디렉토리에 저장되므로 **호스트마다 한 번씩** 해줘야 한다.

```bash
claude                                                   # Claude Code 로그인 (~/.claude)
~/.local/bin/code tunnel user login --provider github    # 터널 로그인 (~/.vscode/cli)
systemctl --user start vscode-tunnel
```

설치 스크립트는 터널이 로그인 안 된 상태면 **일부러 시작하지 않는다**. 그냥 띄우면
만료되는 device code만 계속 다시 찍기 때문이다. 위 세 줄 하고 나면 그 뒤로는 자동이다.

### 3. 붙기 / 관리

```bash
tmux attach -t claude-rc
tmux attach -t vscode-tunnel

systemctl --user status  claude-rc vscode-tunnel
systemctl --user restart claude-rc          # 세션 하나만 재생성
~/.local/bin/code tunnel status             # 터널 상태 (JSON, "Connected" 기대)
```

⚠️ **`tmux-server.service`는 stop/restart 하지 말 것.** tmux 서버 전체를 내리므로
작업 중인 세션까지 다 날아간다. `failed` 표시만 지우려면 `restart`가 아니라
`systemctl --user reset-failed`.

### 4. 설정 (터널 이름, claude rc 작업 디렉토리)

설치 스크립트를 돌릴 때 환경변수로 주면 된다. 플래그(`--name`, `--workdir`)와 같다.

```bash
CLAUDE_RC_WORKDIR=~/tt-metal TUNNEL_NAME=box1 ~/my_configs/setup-remote-access.sh
```

| 변수 | 뜻 |
|------|-----|
| `TUNNEL_NAME` | `vscode.dev/tunnel/<이름>`. 20자 이하 `[a-z0-9-]`로 자동 정규화 |
| `CLAUDE_RC_WORKDIR` | 원격 세션이 생성될 디렉토리. 기본값은 `~/TAPER`가 있으면 그것, 없으면 `$HOME` |
| `CLAUDE_BIN` / `CODE_BIN` | 바이너리 자동 탐색 대신 직접 지정 |

- 준 값은 `~/.config/my_configs/remote-access.env`에 **저장된다.** systemd user unit은
  셸 환경을 물려받지 않아서, 부팅 때 launcher가 읽을 수 있는 건 파일뿐이기 때문이다.
  환경변수는 입력 수단일 뿐이고 실제 저장은 파일에 한다. 나중엔 그 파일을 직접 고쳐도 된다.
- 우선순위: 커맨드라인 > 환경변수 > 저장된 파일 > 기본값.
- launcher는 ExecStart 때마다 파일을 읽으므로 **이미 떠 있는 세션엔 반영되지 않는다.**
  값이 바뀌면 스크립트가 `systemctl --user restart claude-rc` 같은 명령을 알려준다.
  자동으로 재시작하지 않는 건 그 세션에 붙어 있는 작업이 날아가기 때문이다.
- 없는 경로를 줘도 unit이 죽지 않고 `$HOME`으로 fallback 한다 (설치 때 경고는 뜬다).

### 5. 구조 (왜 unit이 3개인가)

tmux는 모든 창의 프로세스를 **서버**에서 fork한다. 그래서 전부 서버를 처음 띄운 unit의
cgroup에 잡힌다. 앱 unit이 서버를 소유하면, 전혀 무관한 세션에서 돌린 무거운 작업이
OOM kill을 당할 때 그 앱 unit이 `failed`로 뒤집힌다 (ttdev31, 2026-07-29에 실제로 발생.
`claude rc`는 멀쩡히 돌고 있는데 unit만 죽은 것으로 표시됐다).

그래서 `tmux-server.service`가 서버를 소유하고, `claude-rc` / `vscode-tunnel`은
짧게 실행되는 tmux client만 돌리는 stateless unit으로 둔다. 덕분에 한쪽을
재시작해도 다른 쪽에 영향이 없다. `OOMPolicy=continue`가 나머지 절반이다.

크래시 복구는 systemd가 아니라 tmux 안의 `while true; do <cmd>; sleep N; done`
loop가 한다 (systemd의 `Restart=`는 daemonize된 tmux를 추적할 수 없다). systemd는
부팅 때 세션이 있는지만 보장한다. 이 loop 덕분에 부팅 시 네트워크가 아직 안 올라온
상태여도 터널이 그냥 재시도한다.

호스트별 설정은 레포가 아니라 `~/.config/my_configs/remote-access.env`에 들어간다.
그래서 같은 checkout이 모든 서버에서 그대로 돌아간다.

| 파일 | 역할 |
|------|------|
| `setup-remote-access.sh` | 설치 스크립트 (진입점) |
| `remote-access-common.sh` | 바이너리 탐색·이름 정규화 공용 함수 |
| `tmux-server-up.sh` | tmux 서버 + `main` anchor 세션 |
| `start-claude-rc.sh` | `claude-rc` 세션 |
| `start-vscode-tunnel.sh` | `vscode-tunnel` 세션 |
| `*.service` | systemd user unit 3개 |

---

## Claude Code Ctrl+G → VS Code (tmux 안에서)

tmux 안에서 돌리는 `claude`에서 Ctrl+G(프롬프트를 외부 에디터로 편집)를 누르면
**지금 보고 있는 VS Code 창**에 탭이 뜨고, 탭을 닫으면 내용이 프롬프트로 돌아온다.

### 설치

```bash
ln -sf ~/my_configs/code-wait ~/.local/bin/code-wait
echo 'export EDITOR=~/.local/bin/code-wait' >> ~/.bashrc
```

그다음 **새 tmux pane**에서 `claude`를 다시 띄운다 (이미 떠 있는 프로세스는 옛
`EDITOR`를 들고 있다). 이후엔 VS Code를 껐다 켜도 다시 할 것 없다.

### 왜 `EDITOR="code --wait"`로는 안 되나

- `code`가 어느 VS Code 창에 붙을지는 `VSCODE_IPC_HOOK_CLI`(소켓 경로)로 정해진다.
- tmux 안의 셸은 이 값을 **셸이 시작될 때** 물려받고 끝까지 고정이다.
- 그래서 다음 경우에 옛 소켓을 쥐게 된다.
  - VS Code를 재시작/재접속함 → 새 창은 새 소켓, 기존 pane은 옛 소켓
  - 옛 VS Code 터미널이 같은 tmux 세션에 아직 attach돼 있음 → "첫 번째 client"가 죽은 창
- 옛 소켓도 연결은 되므로 에러가 안 난다. 안 보이는 창에 파일이 열리고
  `--wait`가 멈춰서 **Ctrl+G가 그냥 안 먹는 것처럼** 보인다.

### 동작 방식 (`code-wait`)

1. Ctrl+G를 **누르는 순간** `tmux list-clients`에서 `client_activity`가 가장 최근인
   client(= 지금 타이핑 중인 VS Code 터미널)를 고른다.
2. 그 프로세스의 `/proc/<pid>/environ`에서 `VSCODE_IPC_HOOK_CLI`와 remote-cli `code`
   경로를 가져온다.
3. `code --wait "$@"`로 연다.

- tmux 밖(VS Code 터미널 직접)에서도 자기 환경값 그대로 동작한다.
- VS Code 없이 ssh로만 붙은 경우엔 `vi`로 fallback 한다 (`CODE_WAIT_FALLBACK=nano` 등으로 변경).

### 안 될 때 확인

```bash
echo $EDITOR                                                 # ~/.local/bin/code-wait 여야 함
tmux list-clients -F '#{client_tty} #{t:client_activity}'    # 죽은 client가 최신이면 문제
tmux detach-client -t /dev/pts/N                             # 안 쓰는 client 떼기
```

---

## AutoVPN (Windows)

openconnect(Fortinet) 기반 moreh VPN을 **scheduled task 두 개로 상시 유지**한다.
로그온·절전 해제·잠금 해제 때 알아서 붙고, 끊기면 원인을 보고 다시 붙고, supervisor가
죽으면 1분 안에 되살린다. 자세한 설계와 장애 분석은 [autovpn/README.md](autovpn/README.md).

### 설치

사전 조건: [OpenConnect-GUI](https://github.com/openconnect/openconnect-gui/releases)
(openconnect.exe + wintun.dll).

```powershell
git clone https://github.com/iwooook/my_configs.git
cd my_configs\autovpn
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

UAC 한 번 승인하고 VPN 비밀번호를 입력하면 끝이다. 비밀번호는 DPAPI로 암호화돼
`%LOCALAPPDATA%\AutoVPN\`에 저장된다. 사용자+장비에 묶이므로 **PC마다 `install.ps1`을
따로 돌려야 한다** (복사해도 복호화 안 됨).

scheduled task는 `install.ps1`을 실행한 위치의 스크립트를 가리킨다. 폴더를 옮기면
`install.ps1`을 다시 돌린다 (`-SkipCredential`을 주면 비밀번호는 그대로 둔다).

### 구조

| task | 스크립트 | 트리거 | 하는 일 |
|------|----------|--------|---------|
| `AutoVPN` | `vpn-auto.ps1` | 로그온 +30초 / 절전 해제 +15초 / 잠금 해제 +5초 | supervisor. openconnect를 띄우고, 끊기면 원인별로 재연결 |
| `AutoVPN-Watchdog` | `watchdog.ps1` | 1분마다 | supervisor가 죽었으면 다시 시작 |

오래 버티는 이유 (자세한 건 [autovpn/README.md](autovpn/README.md)):

- **keepalive 겸 health probe**: 30초마다 터널 안쪽 내부 호스트에 TCP 접속한다. 게이트웨이
  idle timeout(60분)을 막고, "연결은 됐는데 통신 안 되는" 터널을 3회 실패로 잡아 재시작한다.
- **원인별 대응**: 인증서 문제(`CERT`)는 AIA로 CA 번들을 재생성하고, 게이트웨이 차단(`BLOCKED`)은
  15분 쉬고, 비번 거부(`AUTH`)는 2회에서 멈춘다. 전부 3초 재시도하던 옛 스크립트가
  게이트웨이 IP 차단을 불렀던 게 이 설계의 출발점이다.
- **halt flag**: supervisor가 일부러 포기한 경우(비번 거부 등)엔 watchdog이 되살리지 않는다.
  "죽으면 되살린다"가 "거부된 비번으로 영원히 재시도"로 변하는 걸 막는다.
- **절전 대응**: 절전 해제를 wall-clock 점프로 감지해 즉시 재연결한다(`RESUME`). task엔
  `StopOnIdleEnd=false`가 필수다. 기본값(true) 때문에 한 달간 절전에서 돌아올 때마다
  스케줄러가 supervisor를 조용히 죽였다.

### 운영

```powershell
Get-ScheduledTask AutoVPN, AutoVPN-Watchdog | Select TaskName, State   # 상태
Get-Content "$env:LOCALAPPDATA\AutoVPN\autovpn.log" -Tail 40 -Wait      # 로그
Stop-ScheduledTask AutoVPN; Start-ScheduledTask AutoVPN                 # 재시작
powershell -ExecutionPolicy Bypass -File .\setup-cred.ps1               # 비번 변경
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1                # 제거
```

정상이면 로그에 `heartbeat: tunnel healthy (Nm up, probe ok)`가 ~5분마다 찍힌다.
끊겼을 땐 `session ended after Ns -- cause: XXX` 줄의 분류를 보면 원인이 나온다.

---

## dotfiles

`setup-remote-access.sh`와 무관하게, 필요하면 직접 복사해서 쓴다.

| 파일 | 내용 |
|------|------|
| `.vimrc` | Vundle 사용. 처음엔 `git clone https://github.com/VundleVim/Vundle.vim.git ~/.vim/bundle/Vundle.vim` 후 vim에서 `:PluginInstall` |
| `.tmux.conf` | Ctrl+←/→ 단어 이동 포함 |
| `logid.cfg` | Logitech M590 (logiops) |

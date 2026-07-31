# my_configs

개인 서버 설정 모음. 새 서버를 받으면 여기 clone 해서 필요한 것만 적용한다.

```bash
git clone https://github.com/iwooook/my_configs.git ~/my_configs
```

## 원격 접속 상시화 (claude rc + VS Code tunnel)

리붓·크래시와 무관하게 **밖에서 항상 붙을 수 있는 상태**를 만든다. tmux 기본 소켓의
세션 두 개로 돌아가고, systemd `--user` 가 부팅 때 띄운다.

| 세션 | 하는 일 | 밖에서 접속 |
|------|---------|-------------|
| `claude-rc` | `claude rc` | claude.ai/code + 모바일 앱 |
| `vscode-tunnel` | `code tunnel` | `https://vscode.dev/tunnel/<호스트명>` |

### 설치

```bash
~/my_configs/setup-remote-access.sh --check   # 뭐가 없는지만 확인 (아무것도 안 바꿈)
~/my_configs/setup-remote-access.sh           # 실제 설치
```

여러 번 돌려도 안전하다. 이미 떠 있는 세션은 건드리지 않는다 (`start`만 쓰고
`restart`는 안 쓴다).

하는 일: 런처를 `~/.local/bin`에 심볼릭 링크 → 유닛 3개를 `~/.config/systemd/user`에
설치 → `loginctl enable-linger` (로그인 안 해도 부팅 때 뜨게) → enable + start.
VS Code CLI가 없으면 받아서 `~/.local/bin/code`에 넣는다.

옵션: `--no-tunnel`, `--no-claude-rc`, `--no-download`, `--name <터널이름>`,
`--workdir <경로>`

### 설정 (터널 이름, claude rc 작업 디렉토리)

돌릴 때 환경변수로 주면 된다. 플래그(`--name`, `--workdir`)와 동등하다.

```bash
CLAUDE_RC_WORKDIR=~/tt-metal TUNNEL_NAME=box1 ~/my_configs/setup-remote-access.sh
```

주면 `~/.config/my_configs/remote-access.env`에 **저장된다.** systemd user 유닛은
셸 환경을 물려받지 않으므로, 부팅 때 런처가 읽을 수 있는 곳은 파일뿐이다. 그래서
환경변수는 입력 수단이고 저장은 파일이다. 나중엔 그 파일을 직접 고쳐도 된다.

우선순위: 커맨드라인 > 환경변수 > 저장된 파일 > 기본값(`~/TAPER` 있으면 그것,
없으면 `$HOME`).

런처는 ExecStart 때마다 파일을 읽으므로 **이미 떠 있는 세션엔 반영되지 않는다.**
값이 바뀌면 스크립트가 재시작 명령을 알려준다 (자동으로 재시작하지 않는 이유는
그 세션에 붙어 있는 작업이 날아가기 때문).

```bash
systemctl --user restart claude-rc
```

없는 경로를 줘도 유닛이 죽지 않고 `$HOME`으로 폴백한다 (설치 때 경고는 뜬다).

| 변수 | 뜻 |
|------|-----|
| `TUNNEL_NAME` | `vscode.dev/tunnel/<이름>`; 20자 이하 `[a-z0-9-]`로 자동 정규화 |
| `CLAUDE_RC_WORKDIR` | 원격 세션이 생성될 디렉토리 |
| `CLAUDE_BIN` / `CODE_BIN` | 바이너리 자동탐색 무시하고 직접 지정 |

### 새 서버에서 한 번씩 필요한 것

둘 다 계정 인증이 홈 디렉토리에 저장되므로 **호스트마다 한 번씩** 해줘야 한다.

```bash
claude                                        # Claude Code 로그인 (~/.claude)
~/.local/bin/code tunnel user login --provider github   # 터널 로그인 (~/.vscode/cli)
systemctl --user start vscode-tunnel
```

설치 스크립트는 터널이 로그인 안 된 상태면 **일부러 시작하지 않는다** — 그냥 띄우면
만료되는 device code만 계속 다시 찍기 때문. 위 두 줄 하고 나면 그 뒤로는 자동이다.

### 붙기 / 관리

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

### 구조 (왜 유닛이 3개인가)

tmux는 모든 창의 프로세스를 **서버**에서 fork한다. 그래서 서버를 처음 띄운 유닛의
cgroup에 전부 계상된다. 앱 유닛이 서버를 소유하면, 전혀 무관한 세션에서 돌린 무거운
작업이 OOM 킬을 맞을 때 그 앱 유닛이 `failed`로 뒤집힌다 (ttdev31, 2026-07-29에
실제로 발생 — `claude rc`는 멀쩡히 돌고 있는데 유닛만 죽은 것으로 표시됐다).

그래서 `tmux-server.service`가 서버를 소유하고, `claude-rc` / `vscode-tunnel`은
짧게 실행되는 tmux 클라이언트만 돌리는 stateless 유닛으로 둔다. 덕분에 한쪽을
재시작해도 다른 쪽에 영향이 없다. `OOMPolicy=continue`가 나머지 절반.

크래시 복구는 systemd가 아니라 tmux 안의 `while true; do <cmd>; sleep N; done`
루프가 한다 (systemd의 `Restart=`는 daemonize된 tmux를 추적할 수 없다). systemd는
부팅 때 세션 존재만 보장한다. 이 루프 덕분에 부팅 시 네트워크가 아직 안 올라온
상태여도 터널이 그냥 재시도한다.

호스트별 설정은 레포가 아니라 `~/.config/my_configs/remote-access.env`에 들어간다.
그래서 같은 checkout이 모든 서버에서 그대로 돌아간다.

### 파일

| 파일 | 역할 |
|------|------|
| `setup-remote-access.sh` | 설치 스크립트 (진입점) |
| `remote-access-common.sh` | 바이너리 탐색·이름 정규화 공용 함수 |
| `tmux-server-up.sh` | tmux 서버 + `main` 앵커 세션 |
| `start-claude-rc.sh` | `claude-rc` 세션 |
| `start-vscode-tunnel.sh` | `vscode-tunnel` 세션 |
| `*.service` | systemd user 유닛 3개 |

## 그 외 dotfile

`setup-remote-access.sh`와 무관하게, 필요하면 직접 복사해서 쓴다.

- `.vimrc` — Vundle 사용. 처음엔
  `git clone https://github.com/VundleVim/Vundle.vim.git ~/.vim/bundle/Vundle.vim` 후
  vim에서 `:PluginInstall`
- `.tmux.conf` — Ctrl+←/→ 단어 이동 포함
- `logid.cfg` — Logitech M590 (logiops)

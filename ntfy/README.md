# ntfy 폰 알림

[ntfy.sh](https://ntfy.sh)는 HTTP POST 한 번으로 폰에 푸시를 보내는 서비스다. 가입·키 없이
**topic 이름만 알면** 보내고 받을 수 있다. 스크립트가 끝났을 때, 뭔가 조건이 맞았을 때
폰으로 알림 받는 용도로 쓴다.

- topic을 아는 사람은 누구나 구독/발송할 수 있다 (= 비밀번호 역할). 이 레포는 public이므로
  **topic은 커밋하지 않고** 머신마다 로컬 파일에 둔다. 아래 예시의 `<TOPIC>`은 그 값으로 바꿔 읽는다.
- 저장 위치: `~/.config/my_configs/ntfy-topic` (한 줄). 셸에서는 `$(cat ~/.config/my_configs/ntfy-topic)`로 쓴다.

```bash
mkdir -p ~/.config/my_configs && echo '<TOPIC>' > ~/.config/my_configs/ntfy-topic   # 새 머신에서 한 번
```

- topic이 새면 새 이름으로 이 파일과 폰 구독만 바꾸면 된다.

## 받는 쪽 (폰)

1. ntfy 앱 설치 (Android: Play Store / F-Droid, iOS: App Store)
2. **Subscribe to topic** → 위 topic 입력 (server는 기본값 `ntfy.sh`)
3. 끝. PC에서는 브라우저로 `https://ntfy.sh/<topic>` 열어도 받는다.

## 보내는 쪽

### curl (Linux / Git Bash)

```bash
curl -s -d "학습 끝남" https://ntfy.sh/<TOPIC>

# 제목·우선순위·태그(이모지)·클릭 시 열 URL
curl -s \
  -H "Title: 서울시향 2석 이상 알림" \
  -H "Priority: urgent" \
  -H "Tags: ticket" \
  -H "Click: https://nol.yanolja.com/ticket/products/25013840" \
  -d "환희의 송가 ①: 19:30 S석 2석" \
  https://ntfy.sh/<TOPIC>

# 긴 명령 끝나면 알림 (성공/실패 구분)
make -j && curl -s -d "build ok" ntfy.sh/<TOPIC> || curl -s -H "Tags: warning" -d "build FAILED" ntfy.sh/<TOPIC>
```

- 한글 제목은 header라서 깨질 수 있다. 깨지면 아래 JSON 방식으로 보낸다.
- `Priority`: `min` `low` `default` `high` `urgent`(=5, 무음모드를 뚫고 길게 울림)
- `Tags`: 이모지 shortcode (`bell`, `ticket`, `warning`, `white_check_mark`, `rotating_light` …)

### JSON (한글 제목, 버튼 넣을 때)

```bash
curl -s https://ntfy.sh/ -H "Content-Type: application/json" -d '{
  "topic": "<TOPIC>",
  "title": "서울시향 2석 이상 알림",
  "message": "환희의 송가 ①: 19:30 S석 2석",
  "priority": 5,
  "tags": ["ticket"],
  "click": "https://nol.yanolja.com/ticket/products/25013840",
  "actions": [{"action": "view", "label": "예매 페이지 열기", "url": "https://nol.yanolja.com/ticket/products/25013840"}]
}'
```

### PowerShell

```powershell
Invoke-RestMethod -Method Post -Uri https://ntfy.sh/ -ContentType 'application/json; charset=utf-8' -Body (
  [Text.Encoding]::UTF8.GetBytes((@{ topic='<TOPIC>'; title='작업 끝'; message='백업 완료'; tags=@('white_check_mark') } | ConvertTo-Json)))
```

### Python (`ntfy_notify.py`)

표준 라이브러리만 쓰는 helper. 복사해 가거나 `sys.path`에 이 폴더를 넣고 import 한다.

```python
from ntfy_notify import notify
notify("서울시향 2석 이상 알림", "환희의 송가 ①: 19:30 S석 2석",
       click=url, priority=5, tags=["ticket"],
       actions=[{"action": "view", "label": "예매 페이지 열기", "url": url}])
```

```bash
python ntfy_notify.py "학습 끝" "epoch 30, loss 0.12" --priority 4 --tags tada
```

topic 순서: 인자 > `$NTFY_TOPIC` > `~/.config/my_configs/ntfy-topic`. 셋 다 없으면 에러.

## 예시 1: Claude Code hook (입력 대기 / 턴 끝 알림)

`~/.claude/settings.json`에 넣으면 Claude가 입력을 기다리거나 턴을 끝낼 때 폰으로 온다.
지금 PC(Windows)에서는 꺼 둔 상태 (2026-11-06, 서울시향 알림만 받으려고). 다시 켜려면 아래를 넣는다.

```json
"hooks": {
  "Notification": [{ "hooks": [{ "type": "command", "shell": "bash",
    "command": "curl -s -o /dev/null -H \"Title: Claude Code\" -H \"Priority: high\" -H \"Tags: bell\" -d \"[$(basename \"$PWD\")] waiting for your input\" https://ntfy.sh/$(cat ~/.config/my_configs/ntfy-topic) || true" }] }],
  "Stop": [{ "hooks": [{ "type": "command", "shell": "bash",
    "command": "curl -s -o /dev/null -H \"Title: Claude Code\" -H \"Tags: white_check_mark\" -d \"[$(basename \"$PWD\")] turn finished\" https://ntfy.sh/$(cat ~/.config/my_configs/ntfy-topic) || true" }] }]
}
```

- `|| true`: 네트워크가 없어도 hook 실패로 Claude가 멈추지 않게.
- `Stop`은 턴마다 오므로 시끄러우면 `Notification`만 남긴다.

## 예시 2: `seatwatch/` 티켓 잔여석 감시 (Windows)

NOL 티켓(구 인터파크) 상품 페이지를 주기적으로 보고, **같은 등급에 N석 이상** 나오면
Windows 알림(알람 소리) + ntfy 푸시(urgent, 「예매 페이지 열기」 버튼) + 예매 페이지 자동 열기.
Task Scheduler에 등록돼서 로그온·재부팅·절전 해제·크래시 후에도 알아서 다시 뜨고, `until` 시각에 끝난다.

### 설치 / 운영

사전 조건: Python, Microsoft Edge, `~/.config/my_configs/ntfy-topic` (위 참고).

```powershell
cd my_configs\ntfy\seatwatch
# config.json 수정: title, shows(이름: 상품 URL), until, threshold, interval
powershell -ExecutionPolicy Bypass -File .\install-task.ps1     # venv+playwright 설치, task 등록, 바로 시작
.venv\Scripts\python watch.py --test-alert                       # 테스트 알림 한 번
Get-Content watch.log -Tail 20 -Wait                              # 로그
Get-ScheduledTask SeatWatch | Select TaskName, State              # 상태
powershell -ExecutionPolicy Bypass -File .\uninstall-task.ps1   # 중지 + task 삭제
```

- config를 바꾸면 `install-task.ps1`을 다시 돌린다 (`until`이 trigger에도 들어가므로). 돌고 있는
  watcher는 옛 config를 들고 있으니 `kill-watcher.ps1`로 한 번 죽이면 10분 안에 새 config로 뜬다.
- `kill-watcher.ps1`은 프로세스만 죽인다. task가 살아 있으면 10분 안에 다시 뜬다.
- 브라우저는 설치된 Edge를 쓴다 (`channel="msedge"`). `playwright install`은 필요 없다.

| config 키 | 뜻 |
|-----------|-----|
| `title` | 알림 제목 (예: `서울시향 2석 이상 알림`) |
| `shows` | `{"표시 이름": "https://nol.yanolja.com/ticket/products/<id>"}` |
| `until` | `YYYY-MM-DD HH:MM`. 이 시각에 감시 종료 + task trigger 만료. 예매 마감(보통 공연 1시간 전)으로 둔다 |
| `threshold` | 한 등급 잔여석이 이 수 이상이면 알림 (기본 2) |
| `interval` | 확인 주기 초 (기본 180, 매번 ±30초) |
| `ntfy_topic` | 비워 둔다 (커밋됨). 비면 `ntfy_notify.py` 규칙대로 로컬 파일에서 찾음 |
| `slack_webhook` | (선택) Slack Incoming Webhook URL. 넣었으면 커밋하지 말 것 |

### task 구조

| trigger | 하는 일 |
|---------|---------|
| 로그온 | 로그인하면 바로 시작 |
| 10분마다 반복 | 죽어 있으면 다시 시작 (재부팅·절전 해제·크래시 복구). `MultipleInstances=IgnoreNew`라 돌고 있으면 무시 |
| `SeatWatch-Health` task, 매일 10:00 | `health.py`: 상태 리포트를 ntfy로 보냄. 그 시각에 PC가 꺼져 있었으면 켜진 뒤 바로 |

- 일일 리포트 내용: task 상태, 프로세스 수, 마지막 확인 시각, 최근 24시간 확인/실패 횟수, 공연별 최신 잔여석, 종료까지 남은 일수.
  task가 Running이 아니거나, 프로세스가 없거나, 마지막 확인이 15분보다 오래됐으면 `⚠ … 감시 이상`(priority high)으로 온다.
  수동 실행: `.venv\Scripts\python health.py`
- 모든 trigger가 `EndBoundary = until`. `watch.py`도 `until`이 지나면 스스로 끝난다.
- `LogonType=Interactive`: Edge 창과 toast를 띄워야 해서 **로그인돼 있을 때만** 돈다.
  재부팅 후엔 로그인해야 시작된다. 관리자 권한은 필요 없다.
- `ExecutionTimeLimit=0`, `DontStopOnIdleEnd`, 배터리 조건 끔. 기본값이면 3일 뒤나 idle 해제 때 스케줄러가 죽인다.

### 알아둘 것


- **잔여석 API는 Cloudflare 봇 차단(403)** 이라 못 쓴다. **headless Edge도 메인 페이지로 튕긴다.**
  그래서 실제 Edge 창을 화면 밖(`--window-position=-32000,-32000`)에 띄워 페이지에 표시된
  `19:30 / R석 0 / S석 0 …` 텍스트를 읽는다. 차단 우회는 하지 않는다.
- 2석이 **연석인지는 모른다.** 배치도는 로그인 후 예매창에서만 보이고, 거기 자동 진입은
  보안문자·매크로 감지·계정 제한 위험이 있어서 안 한다. 알림 받고 배치도는 직접 본다.
- 같은 상태로는 한 번만 알리고, 잔여석 수가 바뀌면 다시 알린다. 6회 연속 실패하면 오류 알림.
- Windows toast는 WinRT라서 pwsh 7이 아니라 `powershell.exe`(5.1)로 띄운다.

"""seatwatch 상태 점검 → ntfy로 일일 리포트. SeatWatch-Health task가 매일 10시에 실행한다.

정상 기준: task가 Running이고, watch.py 프로세스가 있고, 마지막 확인이 15분 이내.
이상이면 priority high + warning 태그로 보낸다.
"""
import datetime, json, pathlib, re, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from ntfy_notify import notify  # noqa: E402

CFG = json.loads((HERE / "config.json").read_text(encoding="utf-8"))
TITLE = CFG.get("title", "seatwatch")
LOG = HERE / "watch.log"
LINE = re.compile(r"^\[(\d\d-\d\d \d\d:\d\d:\d\d)\] (.*)$")
CHECK = re.compile(r"^.+?: \d{1,2}:\d{2} \S+석\d+")
STALE_MIN = 15


def task_and_process():
    ps = ("$t = Get-ScheduledTask -TaskName SeatWatch -ErrorAction SilentlyContinue; "
          "$p = @(Get-CimInstance Win32_Process -Filter \"Name='pythonw.exe' OR Name='python.exe'\" | "
          "Where-Object CommandLine -like '*seatwatch*watch.py*').Count; "
          "@{ state = if ($t) { [string]$t.State } else { 'Missing' }; procs = $p } | ConvertTo-Json -Compress")
    out = subprocess.run(["powershell.exe", "-NoProfile", "-Command", ps],
                         capture_output=True, text=True, encoding="utf-8",
                         creationflags=0x08000000).stdout  # CREATE_NO_WINDOW
    return json.loads(out)


def parse_log(now):
    entries = []
    if LOG.exists():
        for line in LOG.read_text(encoding="utf-8").splitlines()[-3000:]:
            m = LINE.match(line)
            if m:
                ts = datetime.datetime.strptime(f"{now.year}-{m.group(1)}", "%Y-%m-%d %H:%M:%S")
                if ts > now + datetime.timedelta(days=1):   # 연말 넘어가는 경우
                    ts = ts.replace(year=now.year - 1)
                entries.append((ts, m.group(2)))
    return entries


def main():
    now = datetime.datetime.now()
    tp = task_and_process()
    entries = parse_log(now)
    day_ago = now - datetime.timedelta(days=1)
    checks = [(t, msg) for t, msg in entries if CHECK.match(msg)]   # "이름: 19:30 R석0 ..." 줄만
    fails = [(t, msg) for t, msg in entries if "확인 실패" in msg and t >= day_ago]
    checks_24h = [c for c in checks if c[0] >= day_ago]
    last = checks[-1][0] if checks else None
    ago = int((now - last).total_seconds() // 60) if last else None

    latest = {}
    for t, msg in checks:
        name, _, summary = msg.partition(": ")
        latest[name] = summary.replace("  <-- 알림!", "")

    problems = []
    if tp["state"] != "Running":
        problems.append(f"task 상태 {tp['state']}")
    if tp["procs"] == 0:
        problems.append("watch.py 프로세스 없음")
    if ago is None or ago > STALE_MIN:
        problems.append(f"마지막 확인 {'없음' if ago is None else f'{ago}분 전'}")

    until = CFG.get("until")
    lines = [
        f"task {tp['state']} / 프로세스 {tp['procs']}개",
        f"마지막 확인: {last:%m-%d %H:%M} ({ago}분 전)" if last else "마지막 확인: 없음",
        f"최근 24시간: 확인 {len(checks_24h)}회(공연별 합산), 실패 {len(fails)}회",
        *(f"{n}: {s}" for n, s in latest.items()),
    ]
    if until:
        left = datetime.datetime.strptime(until, "%Y-%m-%d %H:%M") - now
        lines.append(f"종료까지 {left.days}일 ({until})")
    if problems:
        lines.insert(0, "문제: " + ", ".join(problems))

    ok = not problems
    notify(f"{'✅' if ok else '⚠'} {TITLE} 감시 {'정상' if ok else '이상'}", "\n".join(lines),
           priority=3 if ok else 4, tags=["ticket"] if ok else ["warning"])
    print("\n".join(lines))


if __name__ == "__main__":
    main()

"""NOL 티켓(구 인터파크) 잔여석 감시 → 같은 등급에 threshold석 이상이면 알림.

알림: Windows toast(알람 소리) + ntfy 폰 푸시 + (선택) Slack webhook + 예매 페이지 자동 열기.
설정: 같은 폴더 config.json. 자세한 건 ../README.md.

잔여석 API는 Cloudflare 봇 차단(403)이라 쓰지 않고, 실제 Edge 창(화면 밖)으로 상품 페이지를
열어 표시된 "19:30 / R석 0 / S석 0 ..."을 읽는다. headless는 메인 페이지로 튕겨서 못 쓴다.
"""
import datetime, json, pathlib, random, re, subprocess, sys, time, urllib.request, webbrowser
from xml.sax.saxutils import escape
from playwright.sync_api import sync_playwright

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
from ntfy_notify import notify as ntfy_send  # noqa: E402

CFG = json.loads((HERE / "config.json").read_text(encoding="utf-8"))
SHOWS = CFG["shows"]
THRESHOLD = CFG.get("threshold", 2)       # 같은 등급 잔여석이 이 수 이상이면 알림
INTERVAL = CFG.get("interval", 180)       # 확인 주기(초), 매번 ±30초 랜덤
TITLE = CFG.get("title", f"잔여석 {THRESHOLD}석 이상 알림")
UNTIL = (datetime.datetime.strptime(CFG["until"], "%Y-%m-%d %H:%M")  # 이 시각이 지나면 종료
         if CFG.get("until") else None)
LOG = HERE / "watch.log"

BLOCK = re.compile(r"(\d{1,2}:\d{2})\s*\n((?:[A-Z가-힣]+석\s*\d+\s*\n?)+)")
SEAT = re.compile(r"([A-Z가-힣]+석)\s*(\d+)")


def log(msg):
    line = f"[{datetime.datetime.now():%m-%d %H:%M:%S}] {msg}"
    print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def toast(title, body, url):
    """Windows toast. reminder scenario라 닫을 때까지 화면에 남고 알람 소리가 반복된다.
    WinRT를 써서 pwsh 7이 아니라 Windows PowerShell(powershell.exe)로 실행해야 한다."""
    xml = f"""<toast scenario="reminder" activationType="protocol" launch="{escape(url)}">
<visual><binding template="ToastGeneric"><text>{escape(title)}</text><text>{escape(body)}</text></binding></visual>
<actions><action content="예매 페이지 열기" activationType="protocol" arguments="{escape(url)}"/>
<action content="닫기" activationType="system" arguments="dismiss"/></actions>
<audio src="ms-winsoundevent:Notification.Looping.Alarm" loop="true"/></toast>"""
    ps = f"""
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime] | Out-Null
$x = New-Object Windows.Data.Xml.Dom.XmlDocument
$x.LoadXml(@'
{xml}
'@)
$app = '{{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}}\\WindowsPowerShell\\v1.0\\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($x))
"""
    subprocess.run(["powershell.exe", "-NoProfile", "-Command", ps], capture_output=True)


def slack(text):
    hook = CFG.get("slack_webhook")
    if not hook:
        return
    try:
        req = urllib.request.Request(hook, data=json.dumps({"text": text}).encode(),
                                     headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=15).read()
    except Exception as e:
        log(f"Slack 전송 실패: {e}")


def notify(title, body, url, priority=5):
    toast(title, body, url)
    try:
        ntfy_send(title, body, click=url, priority=priority, tags=["ticket"],
                  actions=[{"action": "view", "label": "예매 페이지 열기", "url": url}],
                  topic=CFG.get("ntfy_topic") or None)
    except Exception as e:
        log(f"ntfy 전송 실패: {e}")
    slack(f"*{title}*\n{body}\n{url}")


def read_seats(page, url):
    page.goto(url, wait_until="domcontentloaded", timeout=60000)
    page.wait_for_selector("text=/^R석\\s*\\d+$/", timeout=30000)
    page.wait_for_timeout(1000)
    txt = page.inner_text("body")
    return {m.group(1): {g: int(n) for g, n in SEAT.findall(m.group(2))}
            for m in BLOCK.finditer(txt)}


def main():
    if UNTIL and datetime.datetime.now() >= UNTIL:
        log(f"종료 시각({UNTIL:%m-%d %H:%M})이 지나서 시작하지 않음")
        return
    if "--test-alert" in sys.argv:
        notify(f"[테스트] {TITLE}", "알림이 이렇게 뜹니다. '예매 페이지 열기'를 누르면 페이지가 열립니다.",
               next(iter(SHOWS.values())))
        return
    last_alert, fails = {}, 0
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge", headless=False,
                                    args=["--window-position=-32000,-32000"])
        page = browser.new_page(viewport={"width": 1400, "height": 1000})
        log(f"감시 시작: {', '.join(SHOWS)} / 기준 {THRESHOLD}석 / 주기 약 {INTERVAL}s"
            + (f" / {UNTIL:%m-%d %H:%M}까지" if UNTIL else ""))
        while True:
            if UNTIL and datetime.datetime.now() >= UNTIL:
                log(f"종료 시각({UNTIL:%m-%d %H:%M}) 도달, 감시 종료")
                break
            for name, url in SHOWS.items():
                try:
                    seats = read_seats(page, url)
                    if not seats:
                        raise RuntimeError("잔여석 정보를 찾지 못함")
                    fails = 0
                    summary = " | ".join(f"{t} " + " ".join(f"{g}{n}" for g, n in s.items())
                                         for t, s in seats.items())
                    hits = {t: {g: n for g, n in s.items() if n >= THRESHOLD} for t, s in seats.items()}
                    hits = {t: h for t, h in hits.items() if h}
                    log(f"{name}: {summary}" + ("  <-- 알림!" if hits else ""))
                    key = str(hits)
                    if hits and last_alert.get(name) != key:   # 같은 상태로는 한 번만 알림
                        body = ", ".join(f"{t} " + " ".join(f"{g} {n}석" for g, n in h.items())
                                         for t, h in hits.items())
                        notify(TITLE, f"{name}: {body}", url)
                        webbrowser.open(url)
                    last_alert[name] = key if hits else None
                except Exception as e:
                    fails += 1
                    log(f"{name}: 확인 실패 ({fails}회 연속) - {str(e).splitlines()[0]}")
                    if fails == 6:
                        notify(f"⚠ {TITLE} 감시 오류", "연속으로 확인에 실패하고 있습니다. watch.log를 확인하세요.", url, 3)
            time.sleep(INTERVAL + random.randint(-30, 30))


if __name__ == "__main__":
    main()

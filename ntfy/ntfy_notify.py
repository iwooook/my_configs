"""ntfy.sh 폰 푸시 helper. 표준 라이브러리만 사용한다.

topic 찾는 순서: 인자 topic > $NTFY_TOPIC > ~/.config/my_configs/ntfy-topic (한 줄)
topic은 비밀번호 역할이다 (아는 사람은 누구나 구독/발송). 이 레포는 public이라 topic을 커밋하지 않는다.

모듈로:
    from ntfy_notify import notify
    notify("제목", "본문", click="https://...", priority=5, tags=["ticket"],
           actions=[{"action": "view", "label": "열기", "url": "https://..."}])

CLI로:
    python ntfy_notify.py "제목" "본문" [--click URL] [--priority 1-5] [--tags a,b]
"""
import json, os, pathlib, sys, urllib.request

SERVER = os.environ.get("NTFY_SERVER", "https://ntfy.sh")
TOPIC_FILE = pathlib.Path.home() / ".config" / "my_configs" / "ntfy-topic"


def get_topic(topic=None):
    topic = topic or os.environ.get("NTFY_TOPIC")
    if not topic and TOPIC_FILE.exists():
        topic = TOPIC_FILE.read_text(encoding="utf-8").strip()
    if not topic:
        raise RuntimeError(f"ntfy topic 없음: $NTFY_TOPIC 또는 {TOPIC_FILE} 에 설정")
    return topic


def notify(title, message, *, click=None, priority=3, tags=None, actions=None, topic=None):
    """priority: 1(min) 2(low) 3(default) 4(high) 5(urgent, 폰에서 무음모드 뚫고 길게 울림)."""
    payload = {"topic": get_topic(topic), "title": title, "message": message, "priority": priority}
    if click:
        payload["click"] = click
    if tags:
        payload["tags"] = tags          # 이모지 shortcode: bell, ticket, warning, white_check_mark ...
    if actions:
        payload["actions"] = actions
    req = urllib.request.Request(SERVER + "/", data=json.dumps(payload).encode("utf-8"),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="ntfy 푸시 보내기")
    ap.add_argument("title")
    ap.add_argument("message")
    ap.add_argument("--click")
    ap.add_argument("--priority", type=int, default=3)
    ap.add_argument("--tags", help="쉼표 구분")
    a = ap.parse_args()
    try:
        notify(a.title, a.message, click=a.click, priority=a.priority,
               tags=a.tags.split(",") if a.tags else None)
    except Exception as e:
        print(f"ntfy 전송 실패: {e}", file=sys.stderr)
        sys.exit(1)

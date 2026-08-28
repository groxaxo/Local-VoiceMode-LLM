#!/usr/bin/env python3
"""Text bus for talk.sh — lets agents exchange turns as timestamped JSON files
instead of speaking/listening on the microphone.

Layout:  $TALK_BUS_DIR/YYYY-MM-DD/<UTCstamp>Z-<agent>.json
State:   $TALK_BUS_DIR/state/<agent>.read   (last consumed "day/file")

Commands:
  post   <text> [lang]   append a message authored by $TALK_AGENT
  read                   print unread messages from OTHER agents, mark them read
  wait   [timeout_s]     block until an unread message exists, print its text
  tail   [n]             print the last n messages (all agents), newest last
"""
import json, os, sys, time, datetime

BUS = os.path.expanduser(os.environ.get("TALK_BUS_DIR") or "~/.talk-bus")
AGENT = os.environ.get("TALK_AGENT") or "agent"
STATE = os.path.join(BUS, "state")


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def _entries():
    """All messages as (key, path, record) sorted chronologically."""
    out = []
    if not os.path.isdir(BUS):
        return out
    for day in sorted(os.listdir(BUS)):
        d = os.path.join(BUS, day)
        if day == "state" or not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".json"):
                continue
            p = os.path.join(d, fn)
            try:
                with open(p, encoding="utf-8") as f:
                    rec = json.load(f)
            except Exception:
                continue
            out.append((f"{day}/{fn}", p, rec))
    return out


def _state_path():
    os.makedirs(STATE, exist_ok=True)
    return os.path.join(STATE, f"{AGENT}.read")


def _read_marker():
    try:
        with open(_state_path(), encoding="utf-8") as f:
            return f.read().strip()
    except FileNotFoundError:
        return None


def _write_marker(key):
    with open(_state_path(), "w", encoding="utf-8") as f:
        f.write(key)


def cmd_post(text, lang=""):
    now = _now()
    day = os.path.join(BUS, now.strftime("%Y-%m-%d"))
    os.makedirs(day, exist_ok=True)
    stamp = now.strftime("%Y%m%dT%H%M%S%f")[:-3]
    path = os.path.join(day, f"{stamp}Z-{AGENT}.json")
    rec = {
        "ts": now.isoformat().replace("+00:00", "Z"),
        "agent": AGENT,
        "lang": lang,
        "voice": os.environ.get("XAI_TTS_VOICE", ""),
        "spoken": os.environ.get("TALK_SILENT", "0") != "1",
        "text": text,
    }
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    print(path)


def _unread():
    marker = _read_marker()
    entries = _entries()
    if marker is None:
        # First run: an agent joining the bus should see what it missed, so the
        # backlog is replayed by default. TALK_BUS_REPLAY=0 starts from "now".
        if os.environ.get("TALK_BUS_REPLAY") == "0" and entries:
            _write_marker(entries[-1][0])
            return []
        marker = ""
    fresh = [e for e in entries if e[0] > marker and e[2].get("agent") != AGENT]
    return fresh


def cmd_read():
    fresh = _unread()
    if not fresh:
        return 1
    for key, _p, rec in fresh:
        print(f"[{rec.get('agent')}] {rec.get('text','')}")
    _write_marker(_entries()[-1][0])
    return 0


def cmd_wait(timeout_s):
    deadline = None if timeout_s <= 0 else time.time() + timeout_s
    interval = float(os.environ.get("TALK_BUS_POLL_S", "1"))
    _unread()  # establish the marker on first call without replaying
    while True:
        fresh = _unread()
        if fresh:
            for key, _p, rec in fresh:
                print(f"[{rec.get('agent')}] {rec.get('text','')}")
            _write_marker(_entries()[-1][0])
            return 0
        if deadline and time.time() > deadline:
            print("[talk-bus] timed out waiting for a message", file=sys.stderr)
            return 1
        time.sleep(interval)


def cmd_tail(n):
    for key, _p, rec in _entries()[-n:]:
        print(f"{rec.get('ts')} [{rec.get('agent')}] {rec.get('text','')}")
    return 0


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "post":
        cmd_post(rest[0], rest[1] if len(rest) > 1 else "")
        return 0
    if cmd == "read":
        return cmd_read()
    if cmd == "wait":
        return cmd_wait(float(rest[0]) if rest else float(os.environ.get("TALK_BUS_TIMEOUT_S", "1440")))
    if cmd == "tail":
        return cmd_tail(int(rest[0]) if rest else 20)
    print(f"talk_bus: unknown command {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

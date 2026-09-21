#!/bin/bash
# zcode-pet hook — forwards turn lifecycle events to the pet daemon.
# Contract: never block, never emit
# JSON on stdout, never exit non-zero on soft failures. Turn-end detection is
# the sqlite poller's job; this only adds instant "busy" hints and a heartbeat.

set -u
TYPE="${1:-unknown}"

# stdin carries the hook payload; extract session_id defensively (non-JSON
# input must not crash the hook — defensive normalization per video-agent-kit).
INPUT="$(cat 2>/dev/null || true)"
SESSION="$(printf '%s' "$INPUT" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("session_id") or d.get("sessionId") or "")
except Exception:
    print("")
' 2>/dev/null || true)"

DATA_DIR="$HOME/.zcode-pet"
EVENTS="$DATA_DIR/events.jsonl"
BIN="$DATA_DIR/zcode-pet.app/Contents/MacOS/zcode-pet-daemon"
LOG="$DATA_DIR/hook.log"

mkdir -p "$DATA_DIR" 2>/dev/null || true

TS="$(/usr/bin/python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || date +%s)"
printf '{"type":"%s","session":"%s","ts":%s}\n' "$TYPE" "$SESSION" "$TS" >> "$EVENTS" 2>/dev/null || true

# Bound the events file so the daemon's tail never grows unbounded.
if [ -f "$EVENTS" ]; then
  SIZE="$(stat -f%z "$EVENTS" 2>/dev/null || echo 0)"
  if [ "$SIZE" -gt 1048576 ]; then
    tail -n 200 "$EVENTS" > "$EVENTS.tmp" 2>/dev/null && mv "$EVENTS.tmp" "$EVENTS"
  fi
fi

# SessionStart revives the daemon if the LaunchAgent is not running yet
# (first install, or the user quit it). Fire-and-forget.
if [ "$TYPE" = "session_start" ] && [ -x "$BIN" ]; then
  if ! pgrep -f "zcode-pet-daemon" >/dev/null 2>&1; then
    nohup "$BIN" >>"$DATA_DIR/daemon.log" 2>&1 &
  fi
fi

# Heartbeat for hook health (log-side hook failures are silent).
printf '%s %s session=%s\n' "$TS" "$TYPE" "$SESSION" >> "$LOG" 2>/dev/null || true
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
  tail -n 100 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi

exit 0

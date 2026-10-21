#!/bin/bash
# guard_daemon.sh — 守护进程防覆盖哨兵（2026-10-20 黑屏事件起用）
# 每 5s 检查已装二进制是否含 gettasks 符号；被旧版覆盖时：
#   1) 记录完整进程快照到 ~/.zcode-pet/guard.log（抓覆盖者线索）
#   2) 立即重装正确版本并 kickstart
LOG="$HOME/.zcode-pet/guard.log"
BIN="$HOME/.zcode-pet/zcode-pet.app/Contents/MacOS/zcode-pet-daemon"
ROOT="/Users/zhaoliang/guazi/work/zcode-pet"
while true; do
  if [ -f "$BIN" ] && ! strings "$BIN" 2>/dev/null | grep -q gettasks; then
    echo "[$(date '+%F %T')] 检测到旧版二进制（无 gettasks），进程快照：" >> "$LOG"
    ps auxww >> "$LOG" 2>&1
    launchctl list | grep -i pet >> "$LOG" 2>&1
    bash "$ROOT/scripts/install.sh" >> "$LOG" 2>&1
    echo "[$(date '+%F %T')] 已重装正确版本" >> "$LOG"
  fi
  sleep 5
done

#!/bin/bash
# 卸载：停守护进程 + 移除 LaunchAgent（~/.zcode-pet 数据目录保留）
set -euo pipefail
PLIST="$HOME/Library/LaunchAgents/dev.zcode.pet.plist"
launchctl bootout "gui/$UID/dev.zcode.pet" 2>/dev/null || true
rm -f "$PLIST"
pkill -f "zcode-pet-daemon" 2>/dev/null || true
echo "zcode-pet 已卸载（数据目录 ~/.zcode-pet 保留，如需彻底清除请手动删除）"

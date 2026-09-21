#!/bin/bash
# 编译宠物守护进程到稳定位置 ~/.zcode-pet/bin/（不随插件缓存路径变动）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$HOME/.zcode-pet/bin"
mkdir -p "$BIN_DIR"
swiftc -O "$ROOT/daemon/main.swift" -o "$BIN_DIR/zcode-pet-daemon"
echo "built: $BIN_DIR/zcode-pet-daemon"

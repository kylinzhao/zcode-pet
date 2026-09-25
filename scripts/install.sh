#!/bin/bash
# 安装：编译守护进程进 .app bundle → ad-hoc 签名
#      → 写入并加载 LaunchAgent（开机自启）→ 立即启动
# 卸载：scripts/uninstall.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$HOME/.zcode-pet"
APP_BUNDLE="$DATA_DIR/zcode-pet.app"
EXE="$APP_BUNDLE/Contents/MacOS/zcode-pet-daemon"
PLIST="$HOME/Library/LaunchAgents/dev.zcode.pet.plist"

echo "[1/6] 编译守护进程到 .app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
swiftc -O "$ROOT/daemon/main.swift" -o "$EXE"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>zcode-pet-daemon</string>
  <key>CFBundleIdentifier</key><string>dev.zcode.pet</string>
  <key>CFBundleName</key><string>zcode-pet</string>
  <key>CFBundleDisplayName</key><string>zcode-pet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4.1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# 应用图标（访达/强制退出等处的身份标识），签名前补进去。
# 默认 🐾；守护进程启动后若选了皮肤会自动换成对应图标（AppIcon.skin 是对账标记）。
mkdir -p "$APP_BUNDLE/Contents/Resources"
if "$EXE" --gen-icon 🐾 "$APP_BUNDLE/Contents/Resources/AppIcon.icns"; then
  printf 'paw' > "$APP_BUNDLE/Contents/Resources/AppIcon.skin"
else
  echo "  (图标生成失败，不影响运行)"
fi

# 图片皮肤资产（mmx 生成，daemon/assets/pet/*.png）；缺失时守护进程自动降级像素画/emoji
mkdir -p "$APP_BUNDLE/Contents/Resources/pet-art"
if ls "$ROOT"/daemon/assets/pet/*.png >/dev/null 2>&1; then
  cp "$ROOT"/daemon/assets/pet/*.png "$APP_BUNDLE/Contents/Resources/pet-art/"
fi

codesign --force -s - "$APP_BUNDLE" >/dev/null 2>&1 || echo "  (ad-hoc 签名跳过)"

chmod +x "$ROOT/plugins/zcode-pet/hooks/pet_hook.sh"
rm -rf "$DATA_DIR/bin" 2>/dev/null || true

echo "[2/6] 自检..."
"$EXE" --test

echo "[3/6] 写入 LaunchAgent..."
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.zcode.pet</string>
  <key>ProgramArguments</key>
  <array><string>$EXE</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Adaptive</string>
  <key>StandardOutPath</key><string>$DATA_DIR/daemon.log</string>
  <key>StandardErrorPath</key><string>$DATA_DIR/daemon.log</string>
</dict>
</plist>
EOF

echo "[4/6] 清理旧实例并重启..."
# 先杀旧进程再 bootstrap：避免新旧实例并存（宠物窗口/菜单栏图标出现两份）
pkill -x zcode-pet-daemon 2>/dev/null || true
launchctl bootout "gui/$UID/dev.zcode.pet" 2>/dev/null || true
sleep 1
if ! launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null; then
  sleep 2
  launchctl bootstrap "gui/$UID" "$PLIST"
fi
launchctl kickstart "gui/$UID/dev.zcode.pet"

echo "[5/6] 兜底清理残留实例..."
if [ "$(pgrep -x zcode-pet-daemon | wc -l | tr -d ' ')" -gt 1 ]; then
  pkill -ox zcode-pet-daemon 2>/dev/null || true
fi

echo "[6/6] 完成 ✅"
echo "  守护进程 : ${EXE}（登录自启，SessionStart hook 兜底拉起）"
echo "  日志     : $DATA_DIR/daemon.log"

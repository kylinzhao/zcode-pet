#!/bin/bash
# deploy_pet_mac.sh — 桌面侧部署：重建守护进程并按仓库安装机制重启成新版本
#
# 步骤：
#   [1/3] bash daemon/build.sh      先独立编译一遍（编译清单缺文件在此暴露，不污染安装）
#   [2/3] bash scripts/install.sh   编译进 .app bundle（Info.plist 含蓝牙权限键）→
#                                   ad-hoc 签名 → LaunchAgent 重建 → 杀旧实例 → 立即启动
#   [3/3] 打印蓝牙 TCC 授权提示与日志路径
#
# 不烧录设备；固件侧部署见 ai-passport 仓库 scripts/deploy_pet.sh。
# 用法：bash scripts/deploy_pet_mac.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== [1/3] 重建守护进程（daemon/build.sh） =="
bash "$ROOT/daemon/build.sh"

echo "== [2/3] 安装并重启（scripts/install.sh） =="
bash "$ROOT/scripts/install.sh"

echo "== [3/3] 蓝牙授权提示 =="
echo "  首次启动系统会弹蓝牙授权（TCC），请点「允许」；"
echo "  若曾拒绝：系统设置 → 隐私与安全性 → 蓝牙 → 打开 zcode-pet，然后手动重启："
echo "    launchctl kickstart -k gui/\$UID/dev.zcode.pet"
echo "  设备连接状态看菜单栏 🐾 的 tooltip；日志：tail -f ~/.zcode-pet/daemon.log"
echo ""
echo "deploy_pet_mac: 完成 ✅"

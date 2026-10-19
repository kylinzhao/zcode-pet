#!/bin/bash
# provision_esp32.sh — USB 串口配网：把 WiFi 凭据发给宠物设备（FoloToy AI Passport）
#
# 协议（与固件 zcp_provision.c 约定一致）：
#   Mac → 设备：单行 "ZCP <ssid> <pass>\r\n"（pass 可含空格，取行内剩余全部）
#   设备 → Mac：回执 "ZCP-ACK <ssid>"（成功，已写 NVS）或 "ZCP-ERR <原因>"（失败）
# 设备端在 ConfigPage 开 120s 读行窗口；设备须先插 USB（ConfigPage 会提示）。
#
# 用法：bash scripts/provision_esp32.sh <ssid> <password> [串口设备]
#   例：bash scripts/provision_esp32.sh HomeWiFi "p@ss word"
# 不传串口时自动探测 /dev/cu.usbmodem*。绝不烧录设备，只发一行配网文本。

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "用法: $0 <ssid> <password> [串口设备]"
    echo "  ssid 不含空格；password 可含空格（用引号包住）"
    exit 1
fi
SSID="$1"
PASS="$2"
PORT="${3:-}"

# 定位串口（macOS：cu.* 为呼叫设备，拨号无 DCD 翻译）
if [ -z "$PORT" ]; then
    PORT="$(ls /dev/cu.usbmodem* 2>/dev/null | head -1 || true)"
    if [ -z "$PORT" ]; then
        echo "✗ 未发现 USB 串口（/dev/cu.usbmodem*）——设备插上 USB 后重试，或显式传入端口"
        exit 1
    fi
fi
if [ ! -w "$PORT" ]; then
    echo "✗ 串口不可写: $PORT"
    exit 1
fi
echo "串口: $PORT"

# 115200 8N1 raw；打开串口可能触发 ESP32-C3 USB-Serial/JTAG 复位，留出启动时间
stty -f "$PORT" 115200 raw -echo 2>/dev/null || stty -f "$PORT" 115200 raw
sleep 2

RX="$(mktemp)"
cleanup() { kill "$(cat "$RX.pid" 2>/dev/null)" 2>/dev/null || true; rm -f "$RX" "$RX.pid"; }
trap cleanup EXIT

# 后台收流（设备可能先吐启动日志，一并落盘）
cat "$PORT" > "$RX" 2>/dev/null &
echo $! > "$RX.pid"

printf 'ZCP %s %s\r\n' "$SSID" "$PASS" > "$PORT"
echo "已发送配网行（ZCP <ssid> <pass>），等设备回执……"

# 轮询回执，最长 60s（设备端读行窗口 120s，超时多半是没进 ConfigPage）
for _ in $(seq 1 60); do
    if grep -q "ZCP-ACK" "$RX" 2>/dev/null; then
        echo "✓ 设备回执: $(grep -o 'ZCP-ACK.*' "$RX" | head -1)"
        echo "配网成功，设备转入连接 WiFi。"
        exit 0
    fi
    if grep -q "ZCP-ERR" "$RX" 2>/dev/null; then
        echo "✗ 设备拒绝: $(grep -o 'ZCP-ERR.*' "$RX" | head -1)"
        exit 1
    fi
    sleep 1
done
echo "✗ 60s 内未收到回执——确认设备停在配网页（PetPage 长按 OK 进入），再重试"
exit 1

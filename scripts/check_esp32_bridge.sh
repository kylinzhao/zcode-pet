#!/bin/bash
# check_esp32_bridge.sh — zcode-pet ESP32 桥接侧固定校验
#
# 无设备、无网络、无 GUI、不触发蓝牙 TCC 弹窗（selftest 不创建 CBCentralManager），
# 依赖仅 macOS 自带 swiftc + python3（Xcode CLT）。
#   [1/4] swiftc -O 编译 daemon/main.swift + daemon/DeviceBridge.swift
#         （= scripts/install.sh 编译清单的等价校验：桥接代码可构建/语法正确）
#   [2/4] --bridge-selftest scripts/device_strings.txt
#         协议编码 / BLE 链路状态机（订阅→online、断开 0/1/2/5s 退避、10s 看门狗判死）
#         + 桌面同步断言：update() 12 条合成文案的去 emoji 投影与 # sync: 区逐条一致
#   [3/4] device_strings.txt 结构断言：mid 1-16 全覆盖恰一次、两区无 emoji/表外字符、
#         无 UDP/USB 配网遗留键（CFG_*/WIFI_*/RETRY_FMT 已随 BLE 化退役）
#   [4/4] 跨仓一致性：daemon/DeviceBridge.swift 与 ai-passport main/zcp_bridge.h 的
#         3 个 GATT UUID 逐字节 diff + 消息 t 集合 {hello,status,ack,read} diff
#         （AI_PASSPORT_DIR 可覆盖目标仓路径，缺省 ../ai-passport；目录不存在即 FAIL
#         ——两仓必须共存，固件侧 UUID 见其 zcp_bridge.h）
#
# 设备资产生成另有 scripts/gen_device_assets.sh（烘焙 .zpf + 字体子集 + 码点登记）。

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STRINGS="$ROOT/scripts/device_strings.txt"
PASSPORT_DIR="${AI_PASSPORT_DIR:-$ROOT/../ai-passport}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== [1/4] swiftc 编译 =="
swiftc -O "$ROOT/daemon/main.swift" "$ROOT/daemon/DeviceBridge.swift" -o "$TMP/zcp-check"
echo "编译 OK → $TMP/zcp-check"

echo "== [2/4] --bridge-selftest =="
"$TMP/zcp-check" --bridge-selftest "$STRINGS"

echo "== [3/4] device_strings.txt 结构断言 =="
python3 - "$STRINGS" <<'PY'
import re, sys

text = open(sys.argv[1], encoding='utf-8').read()
section = 0        # 0 头部 1 sync 2 device
sync, device = [], []
errors = []

for lineno, raw in enumerate(text.splitlines(), 1):
    line = raw.strip()
    if line.startswith('# sync:'):
        section = 1; continue
    if line.startswith('# device:'):
        section = 2; continue
    if not line or line.startswith('#'):
        continue
    if '=' not in line:
        errors.append(f"第{lineno}行缺 '=': {line}")
        continue
    key, _, value = line.partition('=')
    key, value = key.strip(), value.strip()
    if not key or not value:
        errors.append(f"第{lineno}行 key/value 为空")
        continue
    if not re.fullmatch(r'[0-9]+|[A-Z][A-Z0-9_]*', key):
        errors.append(f"第{lineno}行 key 非法（应数字 mid 或大写符号）: {key}")
    (sync if section == 1 else device if section == 2 else []).append((key, value, lineno))
    if section == 0:
        errors.append(f"第{lineno}行条目在分区头之前: {key}")

mids = [(k, ln) for k, _, ln in sync + device if k.isdigit()]
seen = {}
for k, ln in mids:
    seen[k] = seen.get(k, 0) + 1
missing = [str(n) for n in range(1, 17) if seen.get(str(n), 0) == 0]
dup = [k for k, c in seen.items() if c > 1]
stray = [k for k in seen if not (1 <= int(k) <= 16)]
if missing: errors.append(f"mid 缺失: {','.join(missing)}")
if dup: errors.append(f"mid 重复: {','.join(dup)}")
if stray: errors.append(f"mid 越界(1-16): {','.join(stray)}")

# UDP/USB 配网已随 BLE 化整体退役，遗留键不再接受
legacy = sorted({k for k, _, _ in device if k.startswith(('CFG_', 'WIFI_')) or k == 'RETRY_FMT'})
if legacy:
    errors.append(f"UDP/USB 配网遗留键未清理（BLE 化后应删除）: {','.join(legacy)}")

# 字符白名单：ASCII 可打印 + ·×…！→ 箭头 + 全角逗号顿号句号 + CJK（与 daemon 内
# DeviceStrings.outsideCharset 同一集合）。emoji（思源黑体无字形）一律拒绝。
def outside(s):
    bad = []
    for ch in s:
        cp = ord(ch)
        ok = (0x20 <= cp <= 0x7e or cp in (0x00b7, 0x00d7, 0x2026, 0xff01, 0xff0c, 0x3001, 0x3002)
              or 0x2190 <= cp <= 0x2193 or 0x3000 <= cp <= 0x9fff)
        if not ok and ch not in bad:
            bad.append(ch)
    return bad

for sec, entries in (('sync', sync), ('device', device)):
    for key, value, lineno in entries:
        for ch in outside(value):
            errors.append(f"{sec}区 {key}（第{lineno}行）含表外字符 U+{ord(ch):04X}「{ch}」")

if errors:
    print(f"device_strings.txt 校验失败（{len(errors)} 项）：")
    for e in errors:
        print(f"  ✗ {e}")
    sys.exit(1)
print(f"sync 区 {len(sync)} 条 / device 区 {len(device)} 条；mid 1-16 全覆盖恰一次；无配网遗留键；字符集 OK")
PY

echo "== [4/4] 跨仓一致性（DeviceBridge.swift ↔ $PASSPORT_DIR/main/zcp_bridge.h） =="
python3 - "$ROOT/daemon/DeviceBridge.swift" "$PASSPORT_DIR" <<'PY'
import os, re, sys

mac_path, passport_dir = sys.argv[1], sys.argv[2]
if not os.path.isdir(passport_dir):
    print(f"✗ 找不到固件仓 {passport_dir}（可用 AI_PASSPORT_DIR 覆盖）——两仓必须共存")
    sys.exit(1)
h_path = os.path.join(passport_dir, 'main', 'zcp_bridge.h')
c_path = os.path.join(passport_dir, 'main', 'zcp_bridge.c')
if not os.path.isfile(h_path):
    print(f"✗ 找不到 {h_path}")
    sys.exit(1)

errors = []

# 3 个 GATT UUID：两仓硬编码同常量，逐字节 diff（大小写归一后比较）
UUID_RE = re.compile(r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}')
mac_text = open(mac_path, encoding='utf-8').read()
fw_text = open(h_path, encoding='utf-8').read()
mac_uuids = sorted({m.upper() for m in UUID_RE.findall(mac_text)})
fw_uuids = sorted({m.upper() for m in UUID_RE.findall(fw_text)})
if not fw_uuids:
    errors.append("固件侧 zcp_bridge.h 未声明 BLE UUID——固件尚未 BLE 化，迁移后必须重跑本检查")
elif mac_uuids != fw_uuids:
    for u in mac_uuids:
        if u not in fw_uuids:
            errors.append(f"UUID 仅在 Mac 侧: {u}")
    for u in fw_uuids:
        if u not in mac_uuids:
            errors.append(f"UUID 仅在固件侧: {u}")
else:
    print("UUID 逐字节一致（服务/TX/RX）：")
    for u in mac_uuids:
        print(f"  {u}")

# 消息 t 集合：两侧都必须恰为 {hello,status,ack,read}
MSG_RE = re.compile(r'"(hello|status|ack|read)"')
expected = sorted(['hello', 'status', 'ack', 'read'])
mac_msgs = sorted(set(MSG_RE.findall(mac_text)))
fw_src = fw_text + (open(c_path, encoding='utf-8').read() if os.path.isfile(c_path) else '')
fw_msgs = sorted(set(MSG_RE.findall(fw_src)))
if mac_msgs != expected:
    errors.append(f"Mac 侧消息 t 集合 {mac_msgs} ≠ {expected}")
if fw_msgs != expected:
    errors.append(f"固件侧消息 t 集合 {fw_msgs} ≠ {expected}（zcp_bridge.h/.c 未齐四类）")
if mac_msgs == expected and fw_msgs == expected:
    print(f"消息 t 集合一致：{', '.join(expected)}")

if errors:
    print("✗ 跨仓一致性失败：")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)
PY

# install.sh 的编译清单必须用新桥接文件，且不许残留已删除的 Esp32Bridge.swift
if ! grep -q "DeviceBridge.swift" "$ROOT/scripts/install.sh"; then
    echo "✗ scripts/install.sh 编译清单缺少 daemon/DeviceBridge.swift"
    exit 1
fi
if grep -q "Esp32Bridge" "$ROOT/scripts/install.sh" "$ROOT/daemon/build.sh" "$ROOT/scripts/gen_device_assets.sh"; then
    echo "✗ 编译清单仍引用已删除的 daemon/Esp32Bridge.swift"
    exit 1
fi
echo "install.sh 编译清单 OK"

echo ""
echo "check_esp32_bridge: PASS ✅"

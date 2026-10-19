#!/bin/bash
# check_esp32_bridge.sh — zcode-pet ESP32 桥接侧固定校验
#
# 无设备、无网络、无 GUI，依赖仅 macOS 自带 swiftc + python3（Xcode CLT）。
#   [1/3] swiftc -O 编译 daemon/main.swift + daemon/Esp32Bridge.swift
#         （同时验证 scripts/install.sh 的编译清单可构建）
#   [2/3] --bridge-selftest scripts/device_strings.txt
#         协议编码 / 链路状态机（6s 降级 / 10s 离线 / hello 学 IP / read 回调）
#         + 桌面同步断言：update() 12 条合成文案的去 emoji 投影与 # sync: 区逐条一致
#   [3/3] device_strings.txt 结构断言：mid 1-16 全覆盖恰一次、两区无 emoji/表外字符
#
# 设备资产生成另有 scripts/gen_device_assets.sh（烘焙 .zpf + 字体子集）。

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STRINGS="$ROOT/scripts/device_strings.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== [1/3] swiftc 编译 =="
swiftc -O "$ROOT/daemon/main.swift" "$ROOT/daemon/Esp32Bridge.swift" -o "$TMP/zcp-check"
echo "编译 OK → $TMP/zcp-check"

echo "== [2/3] --bridge-selftest =="
"$TMP/zcp-check" --bridge-selftest "$STRINGS"

echo "== [3/3] device_strings.txt 结构断言 =="
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
print(f"sync 区 {len(sync)} 条 / device 区 {len(device)} 条；mid 1-16 全覆盖恰一次；字符集 OK")
PY

# install.sh 的编译清单必须包含桥接文件（否则装机版丢桥接）
if ! grep -q "Esp32Bridge.swift" "$ROOT/scripts/install.sh"; then
    echo "✗ scripts/install.sh 编译清单缺少 daemon/Esp32Bridge.swift"
    exit 1
fi
echo "install.sh 编译清单 OK"

echo ""
echo "check_esp32_bridge: PASS ✅"

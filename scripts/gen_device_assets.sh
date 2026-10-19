#!/bin/bash
# gen_device_assets.sh — 生成 ESP32 设备端全部资产（Mac 离线产出，入库 ai-passport）
#
# 产物：
#   <AI_PASSPORT>/main/assets/pet/<skin>-<clip>.zpf   12 段动画帧包（--export-esp32 烘焙，
#                                                     ZPF1：16 色 RGB565 + 1bpp 掩码 RLE + 4bpp 索引）
#   <AI_PASSPORT>/main/zcp_strings.c                  mid→文案表（sync 区）+ 设备区具名字符串
#   <AI_PASSPORT>/assets/fonts/zcp_font_16.c          16px 中文子集字体（lv_font_conv --no-compress，
#                                                     码点 = device_strings.txt 两节全文）
#   <AI_PASSPORT>/assets/README.md(.zh_CN.md)         来源/授权/命令/码点登记块
#
# 前置：
#   · AI_PASSPORT_DIR   目标仓库路径（默认 ../ai-passport）
#   · FONT_TTF          CJK 字体 TTF（思源黑体/Noto Sans SC，SIL OFL；
#                       例：FONT_TTF=~/fonts/NotoSansSC.ttf）
#   · lv_font_conv      npm install -g lv_font_conv（已验证 1.5.3）
#   · SKINS             可选逗号分隔皮肤（默认 ball；全家族约 12MB 超分区）
#
# 用法：FONT_TTF=... bash scripts/gen_device_assets.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STRINGS="$ROOT/scripts/device_strings.txt"
OUT="${AI_PASSPORT_DIR:-$ROOT/../ai-passport}"
SKINS="${SKINS:-ball}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== [1/5] 编译守护进程 =="
swiftc -O "$ROOT/daemon/main.swift" "$ROOT/daemon/Esp32Bridge.swift" -o "$TMP/zcp-gen"

echo "== [2/5] 烘焙 .zpf 帧包 → $OUT/main/assets/pet =="
mkdir -p "$OUT/main/assets/pet"
"$TMP/zcp-gen" --export-esp32 "$OUT/main/assets/pet" --skins "$SKINS"

echo "== [3/5] 生成 zcp_strings.c =="
python3 - "$STRINGS" "$OUT/main/zcp_strings.c" <<'PY'
import sys

def c_escape(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')

def parse(path):
    section, sync, device = 0, [], []
    for raw in open(path, encoding='utf-8'):
        line = raw.strip()
        if line.startswith('# sync:'):
            section = 1; continue
        if line.startswith('# device:'):
            section = 2; continue
        if not line or line.startswith('#'):
            continue
        key, _, value = line.partition('=')
        (sync if section == 1 else device if section == 2 else []).append((key.strip(), value.strip()))
    return sync, device

sync, device = parse(sys.argv[1])
out = []
out.append('// 自动生成：zcode-pet scripts/gen_device_assets.sh —— 勿手改；')
out.append('// 源：zcode-pet/scripts/device_strings.txt（sync + device 两节）。')
out.append('// 模板 %d 由调用方 snprintf 填入（数字走 Montserrat fallback 渲染）。')
out.append('')
out.append('// mid → 文案（sync 区 1-11/15 + device 区 12-14/16；{mid 表由状态帧 mid 字段索引}）')
out.append('const char *zcp_string(int mid) {')
out.append('    switch (mid) {')
for key, value in sync + device:
    if key.isdigit():
        out.append(f'    case {key}: return "{c_escape(value)}";')
out.append('    default: return "";')
out.append('    }')
out.append('}')
out.append('')
out.append('// 设备区具名字符串（UI 模板/提示，符号名 = device_strings.txt device 区 key）')
for key, value in device:
    if not key.isdigit():
        out.append(f'#define ZCP_STR_{key} "{c_escape(value)}"')
open(sys.argv[2], 'w', encoding='utf-8').write('\n'.join(out) + '\n')
print(f"zcp_strings.c：{sum(1 for k, _ in sync + device if k.isdigit())} 个 mid + "
      f"{sum(1 for k, _ in device if not k.isdigit())} 个符号")
PY

echo "== [4/5] 子集字体 zcp_font_16.c =="
if ! command -v lv_font_conv >/dev/null 2>&1; then
    echo "✗ 未安装 lv_font_conv —— 先执行：npm install -g lv_font_conv"
    exit 1
fi
if [ -z "${FONT_TTF:-}" ]; then
    echo "✗ 未指定字体源 —— 例：FONT_TTF=~/fonts/NotoSansSC.ttf bash $0（思源黑体/Noto Sans SC，SIL OFL）"
    exit 1
fi
FONT_VERSION="$(lv_font_conv --version 2>/dev/null || echo unknown)"
mkdir -p "$OUT/assets/fonts"
RANGE="$(python3 - "$STRINGS" <<'PY'
import sys
cps = set()
section = 0
for raw in open(sys.argv[1], encoding='utf-8'):
    line = raw.strip()
    if line.startswith('# sync:'): section = 1; continue
    if line.startswith('# device:'): section = 2; continue
    if not line or line.startswith('#') or section == 0: continue
    for ch in line:
        cps.add(ord(ch))
# 空白仅保留空格（模板拼接可能用到）
cps.add(0x20)
cps = sorted(cps)
ranges, start, prev = [], cps[0], cps[0]
for c in cps[1:]:
    if c == prev + 1:
        prev = c; continue
    ranges.append(f"0x{start:X}" if start == prev else f"0x{start:X}-0x{prev:X}")
    start = prev = c
ranges.append(f"0x{start:X}" if start == prev else f"0x{start:X}-0x{prev:X}")
print(','.join(ranges))
PY
)"
lv_font_conv --font "$FONT_TTF" --size 16 --bpp 4 --format lvgl --no-compress \
    --range "$RANGE" -o "$OUT/assets/fonts/zcp_font_16.c"
echo "字体码点范围：$RANGE"
echo "工具版本：lv_font_conv ${FONT_VERSION}（--no-compress：sdkconfig 未启用 LV_USE_FONT_COMPRESSED）"

echo "== [5/5] 登记 assets/README.md(.zh_CN.md) =="
python3 - "$STRINGS" "$OUT" "$FONT_TTF" "$FONT_VERSION" <<'PY'
import sys, datetime

strings_path, out, font_ttf, font_version = sys.argv[1:5]
sync, device, skin_lines = [], [], []
section = 0
for raw in open(strings_path, encoding='utf-8'):
    line = raw.strip()
    if line.startswith('# sync:'): section = 1; continue
    if line.startswith('# device:'): section = 2; continue
    if not line or line.startswith('#') or section == 0: continue
    key, _, value = line.partition('=')
    (sync if section == 1 else device).append((key.strip(), value.strip()))

import glob, os
zpfs = sorted(os.path.basename(p) for p in glob.glob(os.path.join(out, 'main/assets/pet', '*.zpf')))
cps = sorted({ord(ch) for k, v in sync + device for ch in v})
today = datetime.date.today().isoformat()

BEGIN, END = '<!-- zcode-pet device assets:begin -->', '<!-- zcode-pet device assets:end -->'

def block(zh):
    if zh:
        yield f'{BEGIN}'
        yield f'### zcode-pet 设备资产（由 zcode-pet `scripts/gen_device_assets.sh` 于 {today} 生成，勿手改）'
        yield ''
        yield '| 文件 | 内容与来源 |'
        yield '| --- | --- |'
        yield f'| [`../main/assets/pet/`（{len(zpfs)} 个 `.zpf`）] | 桌面宠物矢量引擎离线烘焙的动画帧包（ZPF1：16 色 RGB565 固定调色板 + 1bpp 透明掩码 RLE + 4bpp 索引，118×76 @ 8fps，设备端 2× 上采样）；零手绘贴图 |'
        yield '| [`../main/zcp_strings.c`](../main/zcp_strings.c) | 闭集中文文案表（sync 区 mid 1-16 + 设备区符号），生成自 zcode-pet `scripts/device_strings.txt` |'
        yield f'| [`fonts/zcp_font_16.c`](fonts/zcp_font_16.c) | 16px 中文子集字体；lv_font_conv {font_version}（`--bpp 4 --format lvgl --no-compress`），码点 = device_strings.txt 两节全文（{len(cps)} 个码点）；字体源：Noto Sans SC（思源黑体同源，SIL OFL 1.1） |'
        yield ''
        yield '- 集成：`.zpf` 经 CMakeLists `EMBED_FILES` 逐个嵌入；字体经 `target_sources` 引用。'
        yield '- 画布底色常量：#1A1A1A（RGB565 0x18C3）——半透明像素烘焙时向它压平，宠物页底色必须同色。'
        yield '- 新增/改动文案：改 zcode-pet `scripts/device_strings.txt` 后重跑 gen_device_assets.sh。'
        yield f'{END}'
    else:
        yield f'{BEGIN}'
        yield f'### zcode-pet device assets (generated by zcode-pet `scripts/gen_device_assets.sh` on {today}, do not edit by hand)'
        yield ''
        yield '| File | Content and source |'
        yield '| --- | --- |'
        yield f'| [`../main/assets/pet/`](../main/assets/pet) ({len(zpfs)} `.zpf` files) | Animation frame packs baked offline by the desktop vector pet engine (ZPF1: fixed 16-color RGB565 palette + 1bpp transparency-mask RLE + 4bpp indices, 118×76 @ 8fps, device upsamples 2×); no hand-drawn art |'
        yield '| [`../main/zcp_strings.c`](../main/zcp_strings.c) | Closed-set Chinese string table (sync mids 1-16 + device symbols), generated from zcode-pet `scripts/device_strings.txt` |'
        yield f'| [`fonts/zcp_font_16.c`](fonts/zcp_font_16.c) | 16 px Chinese subset font; lv_font_conv {font_version} (`--bpp 4 --format lvgl --no-compress`), codepoints = full text of device_strings.txt ({len(cps)} codepoints); font source: Noto Sans SC (Source Han Sans family, SIL OFL 1.1) |'
        yield ''
        yield '- Integration: `.zpf` files are embedded one-by-one via CMakeLists `EMBED_FILES`; the font is referenced via `target_sources`.'
        yield '- Canvas background constant: #1A1A1A (RGB565 0x18C3) — semi-transparent pixels are flattened onto it at bake time; the pet page background must use the same color.'
        yield '- To add or change strings: edit zcode-pet `scripts/device_strings.txt` and rerun gen_device_assets.sh.'
        yield f'{END}'

for name, zh in (('README.md', False), ('README.zh_CN.md', True)):
    path = os.path.join(out, 'assets', name)
    if not os.path.exists(path):
        print(f"  (跳过 {name}：目标仓库无此文件)")
        continue
    text = open(path, encoding='utf-8').read()
    new = '\n'.join(block(zh))
    if BEGIN in text and END in text:
        head = text[:text.index(BEGIN)]
        tail = text[text.index(END) + len(END):]
        text = head + new + tail
    else:
        text = text.rstrip('\n') + '\n\n' + new + '\n'
    open(path, 'w', encoding='utf-8').write(text)
    print(f"  已登记 {name}")

print()
print("EMBED_FILES 片段（贴入 ai-passport main/CMakeLists.txt，勿用通配符——EMBED_FILES 不展开）：")
for z in zpfs:
    print(f'  "${{ZCP_ASSET_DIR}}/{z}"')
PY

echo ""
echo "gen_device_assets: 完成 ✅（产物在 ${OUT}）"

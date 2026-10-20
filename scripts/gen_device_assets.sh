#!/bin/bash
# gen_device_assets.sh — 生成 ESP32 设备端全部资产（Mac 离线产出，入库 ai-passport）
#
# 薄转发：生成器唯一实现已移至 ai-passport/scripts/gen_device_assets.sh（产物格式与
# 固件 zcp_strings.c/zcp_font_16.c 强耦合，归 ai-passport 仓库单边维护；本入口保留是
# 因为 zcode-pet 文档与调用习惯是「在 zcode-pet 目录跑」）。
#
# 产物（全部入库 ai-passport）：
#   main/assets/pet/*.zpf                      12 段动画帧包（--export-esp32 烘焙，ZPF2）
#   main/zcp_strings.c/.h                      闭集文案表 + 设备区具名字符串
#   assets/fonts/zcp_font_16.c                 16px 中文子集字体（lv_font_conv --no-compress）
#   assets/fonts/zcp_font_16.codepoints.txt    码点登记（build_pet.sh 覆盖检查的基准）
#
# 前置：
#   · AI_PASSPORT_DIR   目标仓库路径（默认 ../ai-passport）
#   · FONT_TTF          CJK 字体 TTF/OTF（思源黑体/Noto Sans CJK SC，SIL OFL；
#                         缺省 ~/.zcode-pet/fonts/NotoSansCJKsc-Regular.otf）
#   · lv_font_conv      npm install -g lv_font_conv（已验证 1.5.3）
#
# 用法：FONT_TTF=... bash scripts/gen_device_assets.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${AI_PASSPORT_DIR:-$ROOT/../ai-passport}"
GEN="$TARGET/scripts/gen_device_assets.sh"
if [[ ! -f "$GEN" ]]; then
    echo "ERROR: 找不到生成器 ${GEN}（可用 AI_PASSPORT_DIR 指定 ai-passport 仓库路径）" >&2
    exit 1
fi
exec bash "$GEN"

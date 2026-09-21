#!/bin/bash
# 生成 App 图标（🐾 爪印 + 暖色圆角底）→ AppIcon.icns
# 通知横幅左上角的图标取自 App bundle 图标，这里把它补上。
# 用法: make_icon.sh <输出.icns路径>
set -euo pipefail

OUT="${1:?usage: make_icon.sh <output.icns>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MASTER="$WORK/master.png"

# 用 AppKit 把 emoji 渲染成 1024px PNG（显式 bitmap rep，避免 retina 下 lockFocus 尺寸翻倍）
swift - "$MASTER" <<'SWIFT'
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "master.png"

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// 圆角矩形底 + 暖色渐变（橘猫配色）
let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).addClip()
let colors = [NSColor(srgbRed: 1.00, green: 0.80, blue: 0.48, alpha: 1).cgColor,
              NSColor(srgbRed: 0.95, green: 0.55, blue: 0.18, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// 爪印居中
let emoji = NSAttributedString(string: "🐾", attributes: [.font: NSFont.systemFont(ofSize: size * 0.62)])
let bounds = emoji.boundingRect(with: NSSize(width: size, height: size), options: [.usesLineFragmentOrigin])
emoji.draw(at: NSPoint(x: (size - bounds.width) / 2 - bounds.origin.x,
                       y: (size - bounds.height) / 2 - bounds.origin.y))
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
SWIFT

# 1024 母版 → 全套 iconset 尺寸 → icns
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$MASTER" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  s2=$((s * 2))
  sips -z "$s2" "$s2" "$MASTER" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT"
echo "icon ok: $OUT"

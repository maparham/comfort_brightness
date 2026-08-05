#!/usr/bin/env bash
# Regenerates Resources/Icon/AppIcon.icns from Resources/Icon/AppIcon.svg.
# Uses NSImage (CoreSVG) so it needs no tools beyond stock macOS + Xcode CLT.
set -euo pipefail

cd "$(dirname "$0")/.."

SVG="Resources/Icon/AppIcon.svg"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

swift - "$SVG" "$ICONSET" <<'EOF'
import AppKit

let svgPath = CommandLine.arguments[1]
let iconsetPath = CommandLine.arguments[2]

guard let svg = NSImage(contentsOfFile: svgPath) else {
    fatalError("could not load \(svgPath)")
}

// (name, pixel size) pairs for a complete macOS iconset.
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in variants {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
             from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name).png"))
}
EOF

iconutil -c icns "$ICONSET" -o Resources/Icon/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Wrote Resources/Icon/AppIcon.icns"

#!/usr/bin/env bash
# Generate AppIcon.icns from lfg-brandmark.svg
# Requires: rsvg-convert (librsvg) + iconutil (macOS built-in)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LFG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SVG="$LFG_DIR/assets/brand/lfg-icon.svg"
ICONSET="$LFG_DIR/assets/brand/AppIcon.iconset"
ICNS="$LFG_DIR/assets/brand/AppIcon.icns"

if ! command -v rsvg-convert &>/dev/null; then
    echo "Error: rsvg-convert not found. Install with: brew install librsvg"
    exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Render at all required sizes
# iconutil expects specific filenames: icon_NxN.png and icon_NxN@2x.png
render() {
    local size=$1 name=$2
    rsvg-convert -w "$size" -h "$size" "$SVG" -o "$ICONSET/$name"
}

render 16   "icon_16x16.png"
render 32   "icon_16x16@2x.png"
render 32   "icon_32x32.png"
render 64   "icon_32x32@2x.png"
render 128  "icon_128x128.png"
render 256  "icon_128x128@2x.png"
render 256  "icon_256x256.png"
render 512  "icon_256x256@2x.png"
render 512  "icon_512x512.png"
render 1024 "icon_512x512@2x.png"

iconutil --convert icns "$ICONSET" --output "$ICNS"
rm -rf "$ICONSET"

echo "Generated: $ICNS"

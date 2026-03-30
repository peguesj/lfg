#!/usr/bin/env bash
# =============================================================================
# devdrive-icons.sh — Generate and apply custom volume icons for DEVDRIVE volumes
# =============================================================================
# Creates .VolumeIcon.icns for DDRV900-DDRV904 (purple) and YJ_MORE (cyan).
# Uses Python3 + Pillow (with pure-Python fallback) to generate PNGs, then
# iconutil to convert to .icns and SetFile to enable custom icons.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LFG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LFG_DIR/lib/state.sh"
LFG_MODULE="devdrive-icons"

# Icon sizes required by iconutil (filename -> pixel size)
ICON_SIZES=(
    "icon_16x16.png:16"
    "icon_16x16@2x.png:32"
    "icon_32x32.png:32"
    "icon_32x32@2x.png:64"
    "icon_128x128.png:128"
    "icon_128x128@2x.png:256"
    "icon_256x256.png:256"
    "icon_256x256@2x.png:512"
    "icon_512x512.png:512"
    "icon_512x512@2x.png:1024"
)

# Volumes and their colors
VOLUMES=(
    "DDRV900:#c084fc"
    "DDRV901:#c084fc"
    "DDRV902:#c084fc"
    "DDRV903:#c084fc"
    "DDRV904:#c084fc"
    "YJ_MORE:#22d3ee"
)

WORK_DIR="/tmp/lfg-devdrive-icons"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

generate_icons() {
    local vol_name="$1"
    local hex_color="$2"
    local iconset_dir="$WORK_DIR/${vol_name}.iconset"
    local icns_file="$WORK_DIR/${vol_name}.icns"

    mkdir -p "$iconset_dir"

    # Generate PNGs using Python3 + Pillow (preferred) or pure-Python fallback
    python3 << PYEOF
import sys, os

vol_name = "$vol_name"
hex_color = "$hex_color"
iconset_dir = "$iconset_dir"
sizes = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

# Parse hex color
r = int(hex_color[1:3], 16)
g = int(hex_color[3:5], 16)
b = int(hex_color[5:7], 16)

# Short label for icon text
if vol_name.startswith("DDRV"):
    label = vol_name  # e.g. DDRV900
else:
    label = vol_name  # e.g. YJ_MORE

try:
    from PIL import Image, ImageDraw, ImageFont

    def make_icon(size, filename):
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)

        # Rounded rectangle background
        margin = max(1, size // 16)
        radius = max(2, size // 6)
        draw.rounded_rectangle(
            [margin, margin, size - margin, size - margin],
            radius=radius,
            fill=(r, g, b, 255),
        )

        # Dark inner shadow for depth (smaller rect, darker shade)
        if size >= 64:
            inner_margin = margin + max(1, size // 32)
            inner_radius = max(1, radius - 2)
            dr = max(0, r - 30)
            dg = max(0, g - 30)
            db = max(0, b - 30)
            draw.rounded_rectangle(
                [inner_margin, margin + size // 3, size - inner_margin, size - inner_margin],
                radius=inner_radius,
                fill=(dr, dg, db, 80),
            )

        # Text label
        text = label
        if size < 64:
            # Use abbreviated text for small sizes
            text = vol_name[:2]  # DD or YJ

        # Try to use a system font; fall back to default
        font = None
        font_size = max(6, size // 5)
        if size < 64:
            font_size = max(5, size // 3)
        for font_path in [
            "/System/Library/Fonts/SFCompact-Bold.otf",
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
            "/System/Library/Fonts/Helvetica.ttc",
            "/Library/Fonts/Arial Bold.ttf",
        ]:
            if os.path.exists(font_path):
                try:
                    font = ImageFont.truetype(font_path, font_size)
                    break
                except:
                    continue
        if font is None:
            font = ImageFont.load_default()

        # Center the text
        bbox = draw.textbbox((0, 0), text, font=font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        tx = (size - tw) // 2
        ty = (size - th) // 2

        # White text with slight shadow for readability
        if size >= 64:
            draw.text((tx + 1, ty + 1), text, fill=(0, 0, 0, 100), font=font)
        draw.text((tx, ty), text, fill=(255, 255, 255, 255), font=font)

        # Drive icon indicator at bottom
        if size >= 128:
            indicator_y = size - margin - max(4, size // 16)
            indicator_h = max(3, size // 32)
            draw.rounded_rectangle(
                [size // 4, indicator_y, size - size // 4, indicator_y + indicator_h],
                radius=max(1, indicator_h // 2),
                fill=(255, 255, 255, 160),
            )

        out_path = os.path.join(iconset_dir, filename)
        img.save(out_path, "PNG")

    for filename, size in sizes:
        make_icon(size, filename)

    print(f"  Generated icons with Pillow for {vol_name}")

except ImportError:
    # Pillow not available; generate solid-color PNGs from scratch
    import struct, zlib

    def create_png(width, height, red, green, blue):
        """Create a solid-color PNG without any dependencies."""
        def make_chunk(chunk_type, data):
            c = chunk_type + data
            return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)

        header = b'\x89PNG\r\n\x1a\n'
        ihdr = make_chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
        raw = b''
        for y in range(height):
            raw += b'\x00'  # filter byte
            for x in range(width):
                raw += bytes([red, green, blue])
        idat = make_chunk(b'IDAT', zlib.compress(raw))
        iend = make_chunk(b'IEND', b'')
        return header + ihdr + idat + iend

    for filename, size in sizes:
        png_data = create_png(size, size, r, g, b)
        out_path = os.path.join(iconset_dir, filename)
        with open(out_path, 'wb') as f:
            f.write(png_data)

    print(f"  Generated solid-color icons (no Pillow) for {vol_name}")
PYEOF

    if [[ $? -ne 0 ]]; then
        echo "  ERROR: Failed to generate PNGs for $vol_name"
        return 1
    fi

    # Convert iconset to icns
    if ! iconutil --convert icns "$iconset_dir" --output "$icns_file" 2>/dev/null; then
        echo "  ERROR: iconutil failed for $vol_name"
        return 1
    fi

    echo "  Created: $icns_file"
    return 0
}

apply_icon() {
    local vol_name="$1"
    local icns_file="$WORK_DIR/${vol_name}.icns"
    local mount_point="/Volumes/${vol_name}"

    if [[ ! -d "$mount_point" ]]; then
        echo "  SKIP: $vol_name not mounted"
        return 0
    fi

    if [[ ! -f "$icns_file" ]]; then
        echo "  SKIP: No .icns file for $vol_name"
        return 1
    fi

    # Copy icon to volume root
    cp "$icns_file" "$mount_point/.VolumeIcon.icns" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "  ERROR: Could not copy icon to $mount_point (permission denied?)"
        return 1
    fi

    # Enable custom icon via SetFile (requires Xcode Command Line Tools)
    if command -v SetFile &>/dev/null; then
        SetFile -a C "$mount_point" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo "  Applied icon to $mount_point (custom icon flag set)"
        else
            echo "  WARN: Icon copied but SetFile -a C failed for $mount_point"
        fi
    else
        echo "  WARN: SetFile not found (install Xcode CLT: xcode-select --install)"
        echo "        Icon copied to $mount_point/.VolumeIcon.icns but custom flag not set"
    fi

    return 0
}

# --- Main ---
echo "=== DEVDRIVE Volume Icon Generator ==="
echo ""

GENERATED=0
APPLIED=0
SKIPPED=0

for entry in "${VOLUMES[@]}"; do
    vol_name="${entry%%:*}"
    hex_color="${entry##*:}"

    echo "[$vol_name] color=$hex_color"

    if generate_icons "$vol_name" "$hex_color"; then
        GENERATED=$((GENERATED + 1))

        if apply_icon "$vol_name"; then
            APPLIED=$((APPLIED + 1))
        fi
    else
        SKIPPED=$((SKIPPED + 1))
    fi
    echo ""
done

# Refresh Finder to pick up new icons
killall Finder 2>/dev/null && echo "Finder restarted to refresh volume icons." || true

# Cleanup
rm -rf "$WORK_DIR"

echo "=== Done: $GENERATED generated, $APPLIED applied, $SKIPPED skipped ==="

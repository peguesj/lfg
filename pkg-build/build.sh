#!/usr/bin/env bash
# =============================================================================
# pkg-build/build.sh — Build LFG macOS .pkg installer
#
# Usage:
#   bash pkg-build/build.sh             # from repo root
#   bash build.sh                       # from inside pkg-build/
#
# Output: dist/LFG-<version>-installer.pkg
# =============================================================================
set -euo pipefail

# Resolve paths regardless of where script is invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LFG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR"
OUTPUT_DIR="$LFG_DIR/dist"
VERSION="2.4.0"

echo "=== Building LFG $VERSION .pkg ==="
echo "    LFG source : $LFG_DIR"
echo "    Build dir  : $BUILD_DIR"
echo "    Output dir : $OUTPUT_DIR"
echo ""

# --- Verify required tools ---
for tool in pkgbuild productbuild rsync; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: $tool not found. Install Xcode Command Line Tools." >&2
        exit 1
    fi
done

# --- Prepare output directory ---
mkdir -p "$OUTPUT_DIR"

# --- Prepare payload root ---
PAYLOAD_ROOT="$BUILD_DIR/root"
LFG_INSTALL="$PAYLOAD_ROOT/Users/Shared/lfg"
LAUNCH_AGENTS_ROOT="$PAYLOAD_ROOT/Library/LaunchAgents"
BIN_ROOT="$PAYLOAD_ROOT/usr/local/bin"

rm -rf "$PAYLOAD_ROOT"
mkdir -p "$LFG_INSTALL"
mkdir -p "$LAUNCH_AGENTS_ROOT"
mkdir -p "$BIN_ROOT"

echo "[1/6] Copying LFG suite to payload root..."
rsync -a \
    --exclude='.git' \
    --exclude='.claude' \
    --exclude='pkg-build' \
    --exclude='dist' \
    --exclude='*.o' \
    --exclude='*.swp' \
    --exclude='*.DS_Store' \
    --exclude='lib/__pycache__' \
    --exclude='lib/*.pyc' \
    "$LFG_DIR/" "$LFG_INSTALL/"

echo "[2/6] Creating /usr/local/bin/lfg wrapper..."
cat > "$BIN_ROOT/lfg" <<'EOF'
#!/bin/bash
exec /Users/Shared/lfg/lfg "$@"
EOF
chmod +x "$BIN_ROOT/lfg"

echo "[3/6] Updating plist paths for /Users/Shared/lfg install..."
for plist in io.lfg.helper.plist io.lfg.inbox-watcher.plist io.lfg.devdrive-automount.plist; do
    SRC="$LFG_DIR/$plist"
    if [[ -f "$SRC" ]]; then
        sed \
            -e 's|/Users/jeremiah/tools/@yj/lfg|/Users/Shared/lfg|g' \
            "$SRC" > "$LAUNCH_AGENTS_ROOT/$plist"
        echo "    patched: $plist"
    else
        echo "    WARNING: $plist not found, skipping"
    fi
done

echo "[4/6] Setting permissions..."
chmod +x "$LFG_INSTALL/lfg" 2>/dev/null || true
find "$LFG_INSTALL/lib"     -name "*.sh"   -exec chmod +x {} \; 2>/dev/null || true
find "$LFG_INSTALL/scripts" -name "*.sh"   -exec chmod +x {} \; 2>/dev/null || true
find "$LFG_INSTALL/modules" -name "*.sh"   -exec chmod +x {} \; 2>/dev/null || true
chmod +x "$BUILD_DIR/scripts/preinstall"  2>/dev/null || true
chmod +x "$BUILD_DIR/scripts/postinstall" 2>/dev/null || true

echo "[5/6] Building component package (LFG.pkg)..."
pkgbuild \
    --root "$PAYLOAD_ROOT" \
    --scripts "$BUILD_DIR/scripts" \
    --identifier "io.pegues.yj.lfg" \
    --version "$VERSION" \
    --ownership recommended \
    "$OUTPUT_DIR/LFG.pkg"

echo "[6/6] Building product archive (LFG-$VERSION-installer.pkg)..."
productbuild \
    --distribution "$BUILD_DIR/distribution.xml" \
    --resources "$BUILD_DIR/resources" \
    --package-path "$OUTPUT_DIR" \
    "$OUTPUT_DIR/LFG-$VERSION-installer.pkg"

echo ""
echo "=== Build complete ==="
ls -lh "$OUTPUT_DIR/LFG-$VERSION-installer.pkg"
echo ""
echo "Payload contents (first 30 paths):"
pkgutil --payload-files "$OUTPUT_DIR/LFG.pkg" | head -30
echo ""
echo "Install with:  sudo installer -pkg $OUTPUT_DIR/LFG-$VERSION-installer.pkg -target /"

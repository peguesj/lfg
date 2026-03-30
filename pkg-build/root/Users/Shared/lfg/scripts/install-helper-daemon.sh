#!/usr/bin/env bash
# =============================================================================
# install-helper-daemon.sh — Install LFG Helper as a persistent LaunchAgent
# =============================================================================
# Copies io.lfg.helper.plist to ~/Library/LaunchAgents and loads it.
# Idempotent: unloads first if already registered, then reloads.
# =============================================================================
set -euo pipefail

SELF="$0"
[[ -L "$SELF" ]] && SELF="$(readlink "$SELF")"
LFG_DIR="$(cd "$(dirname "$SELF")/.." && pwd)"
PLIST_SRC="$LFG_DIR/io.lfg.helper.plist"
PLIST_DST="$HOME/Library/LaunchAgents/io.lfg.helper.plist"
HELPER_BIN="$LFG_DIR/LFG Helper.app/Contents/MacOS/LFG Helper"
LOG_DIR="$HOME/.config/lfg"

mkdir -p "$LOG_DIR"

# Build helper if needed
if [[ ! -x "$HELPER_BIN" ]] || [[ "$LFG_DIR/menubar.swift" -nt "$HELPER_BIN" ]]; then
    echo "Building LFG Helper.app..."
    make -C "$LFG_DIR" "LFG Helper.app"
fi

# Unload existing (ignore errors if not loaded)
launchctl unload "$PLIST_DST" 2>/dev/null || true

# Copy plist
cp "$PLIST_SRC" "$PLIST_DST"
echo "Installed: $PLIST_DST"

# Load
launchctl load -w "$PLIST_DST"
echo "Loaded: io.lfg.helper"

# Verify
sleep 1
if pgrep -qx "LFG Helper"; then
    echo "LFG Helper is running."
else
    echo "Warning: LFG Helper did not start — check $LOG_DIR/helper.err"
    exit 1
fi

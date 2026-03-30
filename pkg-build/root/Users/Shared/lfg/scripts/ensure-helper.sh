#!/usr/bin/env bash
# =============================================================================
# ensure-helper.sh — Idempotent LFG Helper launcher
# =============================================================================
# Starts LFG Helper.app (menubar monitor) if not already running.
# Safe to call multiple times; exits immediately if already running.
# =============================================================================
set -euo pipefail

SELF="$0"
[[ -L "$SELF" ]] && SELF="$(readlink "$SELF")"
LFG_DIR="$(cd "$(dirname "$SELF")/.." && pwd)"
HELPER_BIN="$LFG_DIR/LFG Helper.app/Contents/MacOS/LFG Helper"
LOG_DIR="${HOME}/.config/lfg"
LOG_FILE="$LOG_DIR/helper.log"

mkdir -p "$LOG_DIR"

# Already running?
if pgrep -qx "LFG Helper" 2>/dev/null; then
    exit 0
fi

# Build if missing or stale
if [[ ! -x "$HELPER_BIN" ]] || [[ "$LFG_DIR/menubar.swift" -nt "$HELPER_BIN" ]]; then
    echo "[ensure-helper] Building LFG Helper.app..." >> "$LOG_FILE"
    make -C "$LFG_DIR" "LFG Helper.app" >> "$LOG_FILE" 2>&1
fi

# Launch detached
echo "[ensure-helper] Starting LFG Helper at $(date)" >> "$LOG_FILE"
nohup "$HELPER_BIN" >> "$LOG_FILE" 2>&1 &
disown $!

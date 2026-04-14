#!/usr/bin/env bash
# =============================================================================
# devdrive-automount.sh — Mount all DEVDRIVE sparse images at login
# =============================================================================
# Called by io.lfg.devdrive-automount LaunchAgent at login.
# Searches known locations for DDRV and YJ_MORE sparse images and mounts them.
# =============================================================================
set -uo pipefail

LOG_DIR="$HOME/.config/lfg"
LOG="$LOG_DIR/automount.log"
mkdir -p "$LOG_DIR" 2>/dev/null

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [automount] $*" >> "$LOG"
}

log "=== Automount starting ==="

# Known volume names to look for
VOLUME_NAMES=("DDRV900" "DDRV901" "DDRV902" "DDRV903" "DDRV-903-LUME" "DDRV904" "DDRV-904-MEMVT" "YJ_MORE")

# Directories to search for sparse images
SEARCH_DIRS=(
    "$HOME/.config/btau"
    "$HOME/.config/lfg/images"
)

# Also search any currently mounted volumes' btau directories
for vol_dir in /Volumes/*/btau; do
    [[ -d "$vol_dir" ]] && SEARCH_DIRS+=("$vol_dir")
done

MOUNTED=0
ALREADY=0
FAILED=0

# First pass: mount by matching volume name to sparse image filename
for vol_name in "${VOLUME_NAMES[@]}"; do
    mount_point="/Volumes/$vol_name"

    # Skip if already mounted
    if [[ -d "$mount_point" ]]; then
        log "Already mounted: $vol_name"
        ALREADY=$((ALREADY + 1))
        continue
    fi

    # Search for sparse image matching this volume name
    FOUND=""
    for search_dir in "${SEARCH_DIRS[@]}"; do
        for ext in sparseimage sparsebundle dmg; do
            img="$search_dir/$vol_name.$ext"
            if [[ -f "$img" ]]; then
                FOUND="$img"
                break 2
            fi
        done
    done

    if [[ -z "$FOUND" ]]; then
        log "No image found for $vol_name"
        continue
    fi

    log "Mounting: $FOUND -> $mount_point"
    if hdiutil attach "$FOUND" -mountpoint "$mount_point" -noverify -noautofsck 2>>"$LOG"; then
        log "Mounted: $vol_name"
        MOUNTED=$((MOUNTED + 1))
    else
        log "FAILED to mount: $FOUND"
        FAILED=$((FAILED + 1))
    fi
done

# Second pass: mount any unmatched sparse images in search dirs
for search_dir in "${SEARCH_DIRS[@]}"; do
    [[ -d "$search_dir" ]] || continue

    for img in "$search_dir"/*.sparseimage "$search_dir"/*.sparsebundle; do
        [[ -f "$img" ]] || continue

        # Extract volume name from filename
        img_name=$(basename "$img")
        img_name="${img_name%.*}"  # remove extension

        # Skip if this is one of the known names already handled
        already_handled=false
        for vol_name in "${VOLUME_NAMES[@]}"; do
            if [[ "$img_name" == "$vol_name" ]]; then
                already_handled=true
                break
            fi
        done
        $already_handled && continue

        mount_point="/Volumes/$img_name"
        if [[ -d "$mount_point" ]]; then
            log "Already mounted (extra): $img_name"
            continue
        fi

        log "Mounting extra image: $img -> $mount_point"
        if hdiutil attach "$img" -mountpoint "$mount_point" -noverify -noautofsck 2>>"$LOG"; then
            log "Mounted extra: $img_name"
            MOUNTED=$((MOUNTED + 1))
        else
            log "FAILED extra: $img"
            FAILED=$((FAILED + 1))
        fi
    done
done

# Count total mounted DDRV volumes
TOTAL_MOUNTED=$(ls -d /Volumes/DDRV* 2>/dev/null | wc -l | tr -d ' ')
YJ_MOUNTED="no"
[[ -d "/Volumes/YJ_MORE" ]] && YJ_MOUNTED="yes"

log "=== Automount complete: mounted=$MOUNTED already=$ALREADY failed=$FAILED total_ddrv=$TOTAL_MOUNTED yj_more=$YJ_MOUNTED ==="

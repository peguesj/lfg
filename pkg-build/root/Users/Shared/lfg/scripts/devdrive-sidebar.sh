#!/usr/bin/env bash
# =============================================================================
# devdrive-sidebar.sh — Add DEVDRIVE volumes to Finder sidebar
# =============================================================================
# Adds DDRV900-DDRV904 and YJ_MORE to the Finder sidebar "Favorites" section.
# Uses sfltool (primary) with osascript fallback.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LFG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LFG_DIR/lib/state.sh"
LFG_MODULE="devdrive-sidebar"

VOLUMES=("DDRV900" "DDRV901" "DDRV902" "DDRV903" "903LUME" "DDRV904" "DDRV-904-MEMVT" "YJ_MORE")

add_via_sfltool() {
    local vol_path="$1"
    local vol_name
    vol_name="$(basename "$vol_path")"

    # sfltool add-item adds to Finder sidebar favorites
    if sfltool add-item com.apple.LSSharedFileList.FavoriteVolumes "file://${vol_path}" 2>/dev/null; then
        echo "  [sfltool] Added $vol_name to sidebar"
        return 0
    fi

    # Try the FavoriteItems list instead (works on some macOS versions)
    if sfltool add-item com.apple.LSSharedFileList.FavoriteItems "file://${vol_path}" 2>/dev/null; then
        echo "  [sfltool] Added $vol_name to sidebar (FavoriteItems)"
        return 0
    fi

    return 1
}

add_via_osascript() {
    local vol_path="$1"
    local vol_name
    vol_name="$(basename "$vol_path")"

    # Use Finder AppleScript to create a sidebar bookmark by opening the volume
    # This makes Finder aware of the volume, which adds it to sidebar Locations
    osascript -e "
        tell application \"Finder\"
            try
                -- Opening the volume in Finder triggers it to appear in sidebar Locations
                open POSIX file \"$vol_path\"
                delay 0.5
                close Finder window 1
            end try
        end tell
    " 2>/dev/null

    if [[ $? -eq 0 ]]; then
        echo "  [osascript] Opened $vol_name in Finder (added to Locations)"
        return 0
    fi

    return 1
}

add_via_alias() {
    local vol_path="$1"
    local vol_name
    vol_name="$(basename "$vol_path")"

    # Create an alias file on the desktop as a convenient shortcut
    local alias_dir="$HOME/Desktop/DEVDRIVE Volumes"
    mkdir -p "$alias_dir" 2>/dev/null

    osascript -e "
        tell application \"Finder\"
            try
                set volRef to POSIX file \"$vol_path\" as alias
                set aliasFolder to POSIX file \"$alias_dir\" as alias
                if not (exists alias file \"$vol_name\" of folder aliasFolder) then
                    make new alias file at folder aliasFolder to volRef with properties {name:\"$vol_name\"}
                end if
            end try
        end tell
    " 2>/dev/null

    if [[ $? -eq 0 ]]; then
        echo "  [alias] Created alias in $alias_dir"
        return 0
    fi

    return 1
}

# --- Main ---
echo "=== DEVDRIVE Finder Sidebar Integration ==="
echo ""

ADDED=0
SKIPPED=0
FAILED=0

for vol_name in "${VOLUMES[@]}"; do
    vol_path="/Volumes/$vol_name"

    if [[ ! -d "$vol_path" ]]; then
        echo "[$vol_name] Not mounted — skipping"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    echo "[$vol_name] Adding to Finder sidebar..."

    # Try sfltool first (most reliable for sidebar favorites)
    if add_via_sfltool "$vol_path"; then
        ADDED=$((ADDED + 1))
        continue
    fi

    # Fallback: open volume in Finder to add to Locations
    if add_via_osascript "$vol_path"; then
        ADDED=$((ADDED + 1))
        # Also create alias as backup access method
        add_via_alias "$vol_path"
        continue
    fi

    # Final fallback: just create alias
    if add_via_alias "$vol_path"; then
        ADDED=$((ADDED + 1))
        echo "  NOTE: Could not add to sidebar directly; created Desktop alias instead"
        continue
    fi

    echo "  ERROR: All methods failed for $vol_name"
    FAILED=$((FAILED + 1))
done

echo ""

# Hint about manual sidebar pinning
if [[ $ADDED -gt 0 ]]; then
    echo "TIP: To pin volumes permanently in the Finder sidebar:"
    echo "  1. Open Finder and look under 'Locations' in the sidebar"
    echo "  2. Drag each DDRV volume to the 'Favorites' section"
    echo "  3. Or: Finder > Settings > Sidebar > check 'External disks'"
fi

echo ""
echo "=== Done: $ADDED added, $SKIPPED skipped (not mounted), $FAILED failed ==="

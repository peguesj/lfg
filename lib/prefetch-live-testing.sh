#!/usr/bin/env bash
# prefetch-live-testing.sh — Pre-warm devdrive volumes and browser/testing deps
# for /live-integration-testing skill.
#
# Responsibilities:
#   1. Mount any unmounted LFG sparsebundles (903LUME, 920COWORK)
#   2. Reload the devdrive symlink forest for each mounted profile
#   3. Redirect Playwright + Puppeteer caches onto the devdrive
#   4. Prefetch Playwright Chromium if not already installed
#
# Usage:
#   ./lib/prefetch-live-testing.sh [--dry-run] [--quiet]
#
# Options:
#   --dry-run   Print what would happen without making changes
#   --quiet     Suppress non-summary output

# Note: -u (nounset) intentionally omitted — Bash 3.2 on macOS treats empty
# arrays as unbound when -u is set, causing false errors. Explicit guards used.
set -eo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=false
QUIET=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --quiet)   QUIET=true ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
LFG="$HOME/tools/@yj/lfg/lfg"
BTAU_DIR="$HOME/.config/btau"
CACHE_DIR="$HOME/.cache"

log()  { "$QUIET" || echo "$*"; }
info() { echo "[prefetch-live-testing] $*"; }

# Tracking lists for summary (pipe-separated strings, Bash 3.2 safe)
MOUNTED_LIST=""
ALREADY_MOUNTED_LIST=""
SYMLINKED_LIST=""
ALREADY_SYMLINKED_LIST=""
PLAYWRIGHT_STATUS=""
DEVDRIVE_VOL=""

append_list() {
    # append_list <varname> <value>
    local var="$1" val="$2"
    local cur
    eval "cur=\$$var"
    if [ -z "$cur" ]; then
        eval "$var=\"$val\""
    else
        eval "$var=\"\$cur|\$val\""
    fi
}

# ── 1. Mount sparsebundles ────────────────────────────────────────────────────
info "Checking sparsebundle mounts..."

for bundle in "$BTAU_DIR"/*.sparsebundle; do
    [ -e "$bundle" ] || continue
    name=$(basename "$bundle" .sparsebundle)
    mount_point="/Volumes/$name"

    if [ -d "$mount_point" ]; then
        log "  already mounted: $mount_point"
        append_list ALREADY_MOUNTED_LIST "$name"
    else
        log "  mounting: $name"
        if "$DRY_RUN"; then
            log "  [dry-run] hdiutil attach $bundle -nobrowse -quiet"
        else
            if hdiutil attach "$bundle" -nobrowse -quiet 2>/dev/null; then
                info "  mounted $mount_point"
                append_list MOUNTED_LIST "$name"
            else
                info "  WARNING: failed to mount $bundle"
            fi
        fi
    fi
done

# ── 2. Reload symlink forest for each mounted profile ─────────────────────────
info "Reloading devdrive symlink forest..."

for bundle in "$BTAU_DIR"/*.sparsebundle; do
    [ -e "$bundle" ] || continue
    name=$(basename "$bundle" .sparsebundle)
    if [ -d "/Volumes/$name" ]; then
        log "  syncing profile: $name"
        if "$DRY_RUN"; then
            log "  [dry-run] $LFG devdrive sync --profile=$name"
        else
            if "$LFG" devdrive sync --profile="$name" 2>/dev/null; then
                log "  synced: $name"
            else
                info "  WARNING: devdrive sync failed for profile=$name (non-fatal)"
            fi
        fi
    fi
done

# ── 3. Redirect browser dep caches to devdrive ────────────────────────────────
info "Setting up browser cache symlinks on devdrive..."

# Prefer 900DEVELOPER if mounted, fall back to 920COWORK
if [ -d "/Volumes/900DEVELOPER" ]; then
    DEVDRIVE_VOL="/Volumes/900DEVELOPER"
    log "  using volume: /Volumes/900DEVELOPER"
else
    DEVDRIVE_VOL="/Volumes/920COWORK"
    log "  using volume: /Volumes/920COWORK (900DEVELOPER not mounted)"
fi

# Process each cache → devdrive mapping
for mapping in \
    "$CACHE_DIR/ms-playwright:$DEVDRIVE_VOL/playwright" \
    "$CACHE_DIR/puppeteer:$DEVDRIVE_VOL/puppeteer"
do
    src="${mapping%%:*}"
    target="${mapping##*:}"
    cache_name=$(basename "$src")

    # Create target dir on devdrive if it doesn't exist
    if [ ! -d "$target" ]; then
        log "  creating devdrive dir: $target"
        if ! "$DRY_RUN"; then
            mkdir -p "$target"
        fi
    fi

    # Check if source is already a symlink pointing to the right place
    if [ -L "$src" ]; then
        current_target=$(readlink "$src")
        if [ "$current_target" = "$target" ]; then
            log "  already symlinked: $src -> $target"
            append_list ALREADY_SYMLINKED_LIST "$cache_name"
            continue
        else
            log "  re-linking (was -> $current_target): $src"
            if ! "$DRY_RUN"; then
                rm "$src"
            fi
        fi
    elif [ -e "$src" ]; then
        # Real directory exists — migrate contents then replace with symlink
        log "  migrating existing cache to devdrive: $src -> $target"
        if ! "$DRY_RUN"; then
            cp -a "$src/." "$target/" 2>/dev/null || true
            rm -rf "$src"
        fi
    fi

    log "  symlinking: $src -> $target"
    if "$DRY_RUN"; then
        log "  [dry-run] ln -s $target $src"
    else
        mkdir -p "$(dirname "$src")"
        ln -s "$target" "$src"
        append_list SYMLINKED_LIST "$cache_name"
    fi
done

# ── 4. Prefetch Playwright browsers ───────────────────────────────────────────
info "Checking Playwright browser installation..."

PLAYWRIGHT_CHROMIUM_PATH="$CACHE_DIR/ms-playwright"

# Detect existing chromium install (any chromium-* subdirectory)
CHROMIUM_FOUND=false
if [ -L "$PLAYWRIGHT_CHROMIUM_PATH" ] || [ -d "$PLAYWRIGHT_CHROMIUM_PATH" ]; then
    if ls "$PLAYWRIGHT_CHROMIUM_PATH"/chromium-* 2>/dev/null | head -1 | grep -q chromium; then
        CHROMIUM_FOUND=true
    fi
fi

if "$CHROMIUM_FOUND"; then
    chromium_ver=$(ls "$PLAYWRIGHT_CHROMIUM_PATH" 2>/dev/null | grep '^chromium-' | head -1 || true)
    log "  Playwright Chromium already installed: $chromium_ver"
    PLAYWRIGHT_STATUS="already installed ($chromium_ver)"
else
    log "  Playwright Chromium not found — installing..."
    if "$DRY_RUN"; then
        log "  [dry-run] npx playwright install --with-deps chromium"
        PLAYWRIGHT_STATUS="would install (dry-run)"
    else
        if command -v npx >/dev/null 2>&1; then
            npx playwright install --with-deps chromium 2>/dev/null || true
            # Re-check after install
            if ls "$PLAYWRIGHT_CHROMIUM_PATH"/chromium-* 2>/dev/null | head -1 | grep -q chromium; then
                chromium_ver=$(ls "$PLAYWRIGHT_CHROMIUM_PATH" 2>/dev/null | grep '^chromium-' | head -1 || true)
                PLAYWRIGHT_STATUS="installed ($chromium_ver)"
            else
                PLAYWRIGHT_STATUS="install attempted (verify manually)"
            fi
        else
            info "  WARNING: npx not found — skipping Playwright install"
            PLAYWRIGHT_STATUS="skipped (npx not found)"
        fi
    fi
fi

# ── 5. Summary ────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  prefetch-live-testing summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "  Volumes:"
if [ -n "$ALREADY_MOUNTED_LIST" ]; then
    IFS='|' read -r -a _items <<< "$ALREADY_MOUNTED_LIST"
    for v in "${_items[@]}"; do
        echo "    already mounted  /Volumes/$v"
    done
fi
if [ -n "$MOUNTED_LIST" ]; then
    IFS='|' read -r -a _items <<< "$MOUNTED_LIST"
    for v in "${_items[@]}"; do
        echo "    newly mounted    /Volumes/$v"
    done
fi
if [ -z "$ALREADY_MOUNTED_LIST" ] && [ -z "$MOUNTED_LIST" ]; then
    echo "    (none processed)"
fi

echo ""
echo "  Devdrive ($DEVDRIVE_VOL):"
if [ -n "$ALREADY_SYMLINKED_LIST" ]; then
    IFS='|' read -r -a _items <<< "$ALREADY_SYMLINKED_LIST"
    for s in "${_items[@]}"; do
        echo "    already symlinked  ~/.cache/$s"
    done
fi
if [ -n "$SYMLINKED_LIST" ]; then
    IFS='|' read -r -a _items <<< "$SYMLINKED_LIST"
    for s in "${_items[@]}"; do
        echo "    symlinked          ~/.cache/$s -> $DEVDRIVE_VOL/$s"
    done
fi
if [ -z "$ALREADY_SYMLINKED_LIST" ] && [ -z "$SYMLINKED_LIST" ]; then
    if "$DRY_RUN"; then
        echo "    (dry-run — no changes made)"
    else
        echo "    (no changes needed)"
    fi
fi

echo ""
echo "  Playwright: $PLAYWRIGHT_STATUS"
echo "  Puppeteer:  cache -> $DEVDRIVE_VOL/puppeteer (installed on first use)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

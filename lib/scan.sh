#!/usr/bin/env bash
# lfg wtfs - Where's The Free Space (disk usage viewer with cross-module integration)
# shellcheck disable=SC1091  # sourced files resolved at runtime
set -euo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIEWER="$LFG_DIR/viewer"

source "$LFG_DIR/lib/state.sh"
# shellcheck disable=SC2034  # LFG_MODULE is read by state.sh after sourcing
LFG_MODULE="wtfs"
HTML_FILE="$LFG_CACHE_DIR/.lfg_scan.html"
source "$LFG_DIR/lib/settings.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# offload-audit subcommand
# Usage: lfg wtfs offload-audit
# Ranks internal home dirs by size, shows DevDrive volume status, and
# identifies directories >500 MB that are not yet offloaded to a DDRV volume.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "offload-audit" ]]; then
    FLEET_JSON="$HOME/DevDrive/fleet.json"
    THRESHOLD_KB=512000   # 500 MB
    TOP_N=20

    # ---- 1. Internal disk stats ----------------------------------------
    DISK_LINE=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print}')
    DISK_USED_KB=$(echo "$DISK_LINE" | awk '{print $3}')
    DISK_FREE_KB=$(echo "$DISK_LINE" | awk '{print $4}')

    fmt_kb() {
        local kb="$1"
        if   (( kb >= 1048576 )); then awk "BEGIN{printf \"%.1f GB\", $kb/1048576}"
        elif (( kb >= 1024    )); then awk "BEGIN{printf \"%.1f MB\", $kb/1024}"
        else echo "${kb} KB"; fi
    }

    DISK_USED_HR=$(fmt_kb "$DISK_USED_KB")
    DISK_FREE_HR=$(fmt_kb "$DISK_FREE_KB")

    # ---- 2. Parse fleet.json via python3 --------------------------------
    #  Outputs tagged lines:
    #    VOLUME <id> <mount> <size> <is_mounted 0|1> <free_kb>
    #    SYMLINK <src_expanded>|<target>   (pipe delimiter; paths may contain spaces)
    #    CONSUMER <expanded_path>
    FLEET_DATA=$(python3 "$LFG_DIR/lib/_offload_audit_parser.py" "$FLEET_JSON" "$HOME")

    # ---- 3. Parse FLEET_DATA into arrays ----------------------------------
    VOL_IDS=(); VOL_MOUNTS=(); VOL_SIZES=(); VOL_MOUNTED=(); VOL_FREE=()
    SL_SRCS=(); SL_TGTS=()
    CONSUMERS=()

    while IFS= read -r fline; do
        case "$fline" in
            VOLUME\ *)
                # shellcheck disable=SC2086
                set -- $fline
                # $1=VOLUME $2=id $3=mount $4=size $5=is_mounted $6=free_kb
                VOL_IDS+=("$2")
                VOL_MOUNTS+=("$3")
                VOL_SIZES+=("$4")
                VOL_MOUNTED+=("$5")
                VOL_FREE+=("$6")
                ;;
            SYMLINK\ *)
                rest="${fline#SYMLINK }"
                sl_src="${rest%%|*}"
                sl_tgt="${rest#*|}"
                SL_SRCS+=("$sl_src")
                SL_TGTS+=("$sl_tgt")
                ;;
            CONSUMER\ *)
                CONSUMERS+=("${fline#CONSUMER }")
                ;;
        esac
    done <<< "$FLEET_DATA"

    # ---- 4. Scan home dir; exclude symlinks and unowned dirs --------------
    SCAN_TMP=$(mktemp)
    while IFS=$'\t' read -r sz_kb dp; do
        [[ "$dp" == "$HOME" ]] && continue
        [[ -L "$dp" ]] && continue
        owner=$(stat -f '%Su' "$dp" 2>/dev/null || echo "?")
        [[ "$owner" != "$(id -un)" ]] && continue
        printf '%s\t%s\n' "$sz_kb" "$dp"
    done < <(du -d1 -k "$HOME" 2>/dev/null | sort -rn) > "$SCAN_TMP"

    # ---- 5. Build lookup strings for fast membership checks ---------------
    SL_SRC_LIST=""
    k=0
    while [[ $k -lt ${#SL_SRCS[@]} ]]; do
        SL_SRC_LIST="${SL_SRC_LIST}|${SL_SRCS[$k]}"
        k=$((k + 1))
    done

    CONSUMER_LIST=""
    c=0
    while [[ $c -lt ${#CONSUMERS[@]} ]]; do
        CONSUMER_LIST="${CONSUMER_LIST}|${CONSUMERS[$c]}"
        c=$((c + 1))
    done

    # ---- 6. Print header --------------------------------------------------
    echo ""
    echo "=== WTFS Offload Audit ==="
    echo "Internal storage: ${DISK_USED_HR} used / ${DISK_FREE_HR} free"
    echo ""

    echo "DevDrive volumes:"
    i=0
    while [[ $i -lt ${#VOL_IDS[@]} ]]; do
        vid="${VOL_IDS[$i]}"
        vmount="${VOL_MOUNTS[$i]}"
        vsize="${VOL_SIZES[$i]}"
        vmounted="${VOL_MOUNTED[$i]}"
        vfree_kb="${VOL_FREE[$i]}"

        if [[ "$vmounted" == "1" ]]; then
            vstatus="MOUNTED"
            free_hr=$(fmt_kb "$vfree_kb")
            vstatus_detail="  ${free_hr} free"
        else
            vstatus="UNMOUNTED"
            vstatus_detail=""
        fi

        printf "  %-20s  [%-9s]  %-35s  %-6s%s\n" \
            "$vid" "$vstatus" "$vmount" "$vsize" "$vstatus_detail"
        i=$((i + 1))
    done
    echo ""

    # ---- 7. Already-offloaded symlinks ------------------------------------
    echo "Already offloaded (fleet.json symlinks -> DevDrive):"
    FOUND_SYMLINKS=0
    OFFLOADED_KB=0
    j=0
    while [[ $j -lt ${#SL_SRCS[@]} ]]; do
        sl_src="${SL_SRCS[$j]}"
        sl_tgt="${SL_TGTS[$j]}"
        src_display="${sl_src/#$HOME/~}"
        if [[ -L "$sl_src" ]]; then
            if [[ -e "$sl_src" ]]; then
                live_status="[LIVE]"
            else
                live_status="[BROKEN]"
            fi
            sl_kb=$(du -sk "$sl_src" 2>/dev/null | awk '{print $1}')
            [[ -n "$sl_kb" ]] && OFFLOADED_KB=$((OFFLOADED_KB + sl_kb))
            printf "  %-40s -> %-40s %s\n" "$src_display" "$sl_tgt" "$live_status"
            FOUND_SYMLINKS=$((FOUND_SYMLINKS + 1))
        fi
        j=$((j + 1))
    done
    [[ $FOUND_SYMLINKS -eq 0 ]] && echo "  (none detected)"
    echo ""

    # ---- 8. Ranked candidate table (top 20) --------------------------------
    printf "%-12s  %-55s  %s\n" "SIZE" "PATH" "STATUS"
    printf "%-12s  %-55s  %s\n" "------------" "-------------------------------------------------------" "--------"

    RANK=0
    CANDIDATE_KB=0
    while IFS=$'\t' read -r sz_kb dp; do
        [[ -z "$dp" ]] && continue
        (( sz_kb < THRESHOLD_KB )) && break   # sorted descending; everything below threshold is too small

        display="${dp/#$HOME/~}"
        label="candidate"

        # Check: already offloaded via a fleet.json symlink
        case "${SL_SRC_LIST}" in
            *"|${dp}"*) label="already-on-devdrive" ;;
        esac

        if [[ "$label" == "candidate" ]]; then
            # Check: resolves into a DDRV volume (unlisted symlink or bind-mount)
            real_dp=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$dp" 2>/dev/null || echo "$dp")
            m=0
            while [[ $m -lt ${#VOL_MOUNTS[@]} ]]; do
                vm="${VOL_MOUNTS[$m]}"
                if [[ -n "$vm" ]] && [[ "$real_dp" == "${vm}"* ]]; then
                    label="already-on-devdrive"; break
                fi
                m=$((m + 1))
            done
        fi

        if [[ "$label" == "candidate" ]]; then
            # Check: iCloud / known internal consumer from fleet.json
            case "${CONSUMER_LIST}" in
                *"|${dp}"*) label="icloud" ;;
            esac
        fi

        if [[ "$label" == "candidate" ]]; then
            # Check: is itself a symlink (missed by pre-filter due to du traversal)
            [[ -L "$dp" ]] && label="symlink"
        fi

        size_hr=$(fmt_kb "$sz_kb")
        printf "%-12s  %-55s  [%s]\n" "$size_hr" "$display" "$label"

        if [[ "$label" == "candidate" ]]; then
            CANDIDATE_KB=$((CANDIDATE_KB + sz_kb))
        fi

        RANK=$((RANK + 1))
        (( RANK >= TOP_N )) && break
    done < "$SCAN_TMP"

    rm -f "$SCAN_TMP"

    [[ $RANK -eq 0 ]] && echo "  (no entries above 500 MB found)"
    echo ""

    # ---- 9. Summary -------------------------------------------------------
    OFFLOADED_HR=$(fmt_kb "$OFFLOADED_KB")
    CANDIDATE_HR=$(fmt_kb "$CANDIDATE_KB")
    echo "Summary:"
    printf "  Total candidate size (not yet offloaded):  %s\n" "$CANDIDATE_HR"
    printf "  Total already-offloaded (symlinked):       %s\n" "$OFFLOADED_HR"
    echo ""
    exit 0
fi

# ---------------------------------------------------------------------------
# Normal WTFS scan (path-based HTML report)
# ---------------------------------------------------------------------------
lfg_state_start wtfs

# Use explicit arg, or configured scan paths
if [[ -n "${1:-}" ]]; then
    SCAN_PATHS=("$1")
else
    # Bash 3.2 compatible (macOS default bash doesn't have mapfile)
    SCAN_PATHS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && SCAN_PATHS+=("$line")
    done < <(lfg_module_paths wtfs 2>/dev/null)
    [[ ${#SCAN_PATHS[@]} -eq 0 ]] && SCAN_PATHS=("$HOME/Developer")
fi

TARGET="${SCAN_PATHS[0]}"
lfg_state_update wtfs target "$TARGET"

echo "Scanning ${#SCAN_PATHS[@]} path(s)..."
TMPFILE=$(mktemp)
for _sp in "${SCAN_PATHS[@]}"; do
    du -d1 -k "$_sp" 2>/dev/null
done | sort -rn > "$TMPFILE"

# Calculate total from all scan path root entries
TOTAL_KB=$(awk '{s+=$1} END{print s+0}' "$TMPFILE")

# Function to check if path is a scan root (Bash 3.2 compatible - no associative arrays)
is_scan_root() {
    local check_path="$1"
    for _sp in "${SCAN_PATHS[@]}"; do
        [[ "$_sp" == "$check_path" ]] && return 0
    done
    return 1
}

ROWS=""
RANK=0
while IFS=$'\t' read -r size_kb path; do
    is_scan_root "$path" && continue
    RANK=$((RANK + 1))
    name=$(basename "$path")

    if (( size_kb >= 1048576 )); then
        size=$(awk "BEGIN{printf \"%.1f GB\", $size_kb/1048576}")
    elif (( size_kb >= 1024 )); then
        size=$(awk "BEGIN{printf \"%.1f MB\", $size_kb/1024}")
    else
        size="${size_kb} KB"
    fi

    if (( TOTAL_KB > 0 )); then
        pct=$(awk "BEGIN{printf \"%.1f\", ($size_kb/$TOTAL_KB)*100}")
    else
        pct="0.0"
    fi


    # Composition breakdown
    deps_kb=0; cache_kb=0
    for dp in node_modules deps vendor Pods .gradle/caches .cargo/registry venv .venv __pypackages__; do
        [[ -d "$path/$dp" ]] && deps_kb=$((deps_kb + $(du -sk "$path/$dp" 2>/dev/null | awk '{print $1}')))
    done
    for cp in .next dist _build target __pycache__ .turbo .cache .parcel-cache .nuxt .output; do
        [[ -d "$path/$cp" ]] && cache_kb=$((cache_kb + $(du -sk "$path/$cp" 2>/dev/null | awk '{print $1}')))
    done
    source_kb=$((size_kb - deps_kb - cache_kb))
    (( source_kb < 0 )) && source_kb=0
    # Segment widths as percentages of this project
    if (( size_kb > 0 )); then
        deps_pct=$(awk "BEGIN{printf \"%.1f\", ($deps_kb/$size_kb)*100}")
        cache_pct=$(awk "BEGIN{printf \"%.1f\", ($cache_kb/$size_kb)*100}")
        source_pct=$(awk "BEGIN{printf \"%.1f\", ($source_kb/$size_kb)*100}")
    else deps_pct="0"; cache_pct="0"; source_pct="0"; fi
    deps_hr=""; cache_hr=""; source_hr=""
    (( deps_kb >= 1024 )) && deps_hr=$(awk "BEGIN{printf \"%.1f MB\", $deps_kb/1024}") || deps_hr="${deps_kb} KB"
    (( cache_kb >= 1024 )) && cache_hr=$(awk "BEGIN{printf \"%.1f MB\", $cache_kb/1024}") || cache_hr="${cache_kb} KB"
    (( source_kb >= 1024 )) && source_hr=$(awk "BEGIN{printf \"%.1f MB\", $source_kb/1024}") || source_hr="${source_kb} KB"

    ROWS+="<tr class=\"clickable\" data-tip=\"${name}: ${size} (${pct}% of total)\">
      <td class=\"rank\">${RANK}</td>
      <td class=\"name\">${name}</td>
      <td class=\"size\">${size}</td>
      <td class=\"bar-cell\"><div class=\"bar-track segmented\" style=\"display:flex\"><div class=\"bar-seg\" style=\"width:${deps_pct}%;background:#4a9eff\" data-tip=\"Deps: ${deps_hr}\"></div><div class=\"bar-seg\" style=\"width:${cache_pct}%;background:#ffd166\" data-tip=\"Cache: ${cache_hr}\"></div><div class=\"bar-seg\" style=\"width:${source_pct}%;background:#06d6a0\" data-tip=\"Source: ${source_hr}\"></div></div></td>
      <td class=\"pct\">${pct}%</td>
    </tr>"
done < "$TMPFILE"
rm -f "$TMPFILE"

if (( TOTAL_KB >= 1048576 )); then
    TOTAL_HR=$(awk "BEGIN{printf \"%.1f GB\", $TOTAL_KB/1048576}")
else
    TOTAL_HR=$(awk "BEGIN{printf \"%.1f MB\", $TOTAL_KB/1024}")
fi

DISK_FREE=$(df -h "$TARGET" | awk 'NR==2{print $4}')
DIR_DISPLAY="${TARGET/#$HOME/\~}"

# Generate HTML via python3 (safe multi-line templating)
LFG_ROWS="$ROWS" python3 -c "
import os
theme = open('$LFG_DIR/lib/theme.css').read()
uijs = open('$LFG_DIR/lib/ui.js').read()
rows = os.environ.get('LFG_ROWS', '')

html = '''<!DOCTYPE html>
<html><head><meta charset=\"utf-8\">
<style>''' + theme + '''</style>
</head><body>
  <div class=\"summary\">
    <div class=\"stat\" data-tip=\"Total size of $DIR_DISPLAY\"><span class=\"label\">Total Used</span><span class=\"value\">$TOTAL_HR</span></div>
    <div class=\"stat\" data-tip=\"Available disk space\"><span class=\"label\">Disk Free</span><span class=\"value accent\">$DISK_FREE</span></div>
    <div class=\"stat\" data-tip=\"$RANK directories scanned\"><span class=\"label\">Directories</span><span class=\"value\">$RANK</span></div>
  </div>
  <div class=\"composition-legend\"><span class=\"legend-item\"><span class=\"legend-dot\" style=\"background:#4a9eff\"></span>Dependencies</span><span class=\"legend-item\"><span class=\"legend-dot\" style=\"background:#ffd166\"></span>Cache/Build</span><span class=\"legend-item\"><span class=\"legend-dot\" style=\"background:#06d6a0\"></span>Source</span></div>
  <table id=\"main-table\">
    <thead><tr><th>#</th><th>Directory</th><th class=\"r\">Size</th><th>Composition</th><th class=\"r\">%</th></tr></thead>
    <tbody>''' + rows + '''</tbody>
  </table>
  <div id=\"action-bar\"></div>
  <div class=\"footer\">lfg wtfs - Local File Guardian | $DIR_DISPLAY</div>
  <script>''' + uijs + '''
  LFG.init({ module: \"wtfs\", context: \"$DIR_DISPLAY\", moduleVersion: \"2.4.0\", welcome: \"Showing $RANK directories in $DIR_DISPLAY\", helpContent: \"<strong>WTFS</strong> shows disk usage for <code>$DIR_DISPLAY</code>.<br><br>Hover rows for details. Largest directories are at the top.<br>Run <code>lfg dtf</code> to find reclaimable caches, or <code>lfg btau</code> for backups.<br><br><strong>Selection:</strong> Click rows to select, Shift+click for range, Cmd+click to toggle, Cmd+A to select all.\" });
  LFG.select.init('main-table');
  document.getElementById(\"action-bar\").appendChild(
    LFG.createCommandPanel(\"WTFS Actions\", [
      { label: \"Scan ~/Developer\", desc: \"Default scan target\", cli: \"lfg wtfs ~/Developer\", module: \"wtfs\", action: \"run\", args: \"~/Developer\", color: \"#4a9eff\" },
      { label: \"Scan Home (~)\", desc: \"Full home directory\", cli: \"lfg wtfs ~\", module: \"wtfs\", action: \"run\", args: \"~\", color: \"#4a9eff\" },
      { label: \"Scan Root (/)\", desc: \"Entire filesystem\", cli: \"lfg wtfs /\", module: \"wtfs\", action: \"run\", args: \"/\", color: \"#ffd166\" },
    ])
  );
  document.getElementById(\"action-bar\").appendChild(
    LFG.createActionBar([
      { label: \"Clean Caches\", color: \"#ff8c42\", onclick: function(){ LFG._postNav('navigate', {target:'dtf'}); }, tip: \"Navigate to DTF\" },
      { label: \"View Backups\", color: \"#06d6a0\", onclick: function(){ LFG._postNav('navigate', {target:'btau'}); }, tip: \"Navigate to BTAU\" },
      { label: \"Devdrive\", color: \"#c084fc\", onclick: function(){ LFG._postNav('navigate', {target:'devdrive'}); }, tip: \"Navigate to DEVDRIVE\" },
      { label: \"Full Dashboard\", color: \"#4a9eff\", onclick: function(){ LFG._postNav('navigate', {target:'dashboard'}); }, tip: \"Navigate to Dashboard\" },
    ])
  );
  </script>
</body></html>'''

open('$HTML_FILE', 'w').write(html)
"

lfg_state_done wtfs "total_size=$TOTAL_HR" "dir_count=$RANK" "target=$DIR_DISPLAY"

if [[ "${LFG_NO_VIEWER:-}" == "1" ]]; then
    echo "Done (headless)."
else
    CHAIN_FILE="/tmp/.lfg_chain_$$"
    echo "Opening viewer..."
    "$VIEWER" "$HTML_FILE" "LFG WTFS - $DIR_DISPLAY" --select "$CHAIN_FILE" &
    VPID=$!
    disown
    (
      while kill -0 "$VPID" 2>/dev/null; do
        if [[ -s "$CHAIN_FILE" ]]; then
          SEL=$(cat "$CHAIN_FILE"); rm -f "$CHAIN_FILE"
          case "$SEL" in
            dtf) "$LFG_DIR/lib/clean.sh" ;; btau) "$LFG_DIR/lib/btau.sh" --view ;;
            devdrive) "$LFG_DIR/lib/devdrive.sh" ;; dashboard) "$LFG_DIR/lib/dashboard.sh" ;;
          esac; break
        fi; sleep 0.3
      done; rm -f "$CHAIN_FILE"
    ) &
    disown
fi

echo "Done."

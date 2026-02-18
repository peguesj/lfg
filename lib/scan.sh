#!/usr/bin/env bash
# lfg wtfs - Where's The Free Space (disk usage viewer with cross-module integration)
set -euo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HTML_FILE="$LFG_DIR/.lfg_scan.html"
VIEWER="$LFG_DIR/viewer"

source "$LFG_DIR/lib/state.sh"
source "$LFG_DIR/lib/settings.sh" 2>/dev/null || true
lfg_state_start wtfs

# Use explicit arg, or configured scan paths
if [[ -n "${1:-}" ]]; then
    SCAN_PATHS=("$1")
else
    mapfile -t SCAN_PATHS < <(lfg_module_paths wtfs 2>/dev/null)
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

# Build set of scan path roots to skip in output
declare -A SCAN_ROOT_SET
for _sp in "${SCAN_PATHS[@]}"; do
    SCAN_ROOT_SET["$_sp"]=1
done

ROWS=""
RANK=0
while IFS=$'\t' read -r size_kb path; do
    [[ -n "${SCAN_ROOT_SET[$path]+x}" ]] && continue
    RANK=$((RANK + 1))
    name=$(basename "$path")

    if (( size_kb >= 1048576 )); then
        size=$(awk "BEGIN{printf \"%.1f GB\", $size_kb/1048576}")
    elif (( size_kb >= 1024 )); then
        size=$(awk "BEGIN{printf \"%.1f MB\", $size_kb/1024}")
    else
        size="${size_kb} KB"
    fi

    pct=$(awk "BEGIN{printf \"%.1f\", ($size_kb/$TOTAL_KB)*100}")
    bar_w="$pct"

    if (( $(echo "$pct > 20" | bc -l) )); then color="#ff4d6a"
    elif (( $(echo "$pct > 10" | bc -l) )); then color="#ff8c42"
    elif (( $(echo "$pct > 5" | bc -l) )); then color="#ffd166"
    elif (( $(echo "$pct > 2" | bc -l) )); then color="#06d6a0"
    else color="#4a9eff"
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
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
DIR_DISPLAY=$(echo "$TARGET" | sed "s|$HOME|~|")

# Generate HTML via python3 (safe multi-line templating)
python3 -c "
theme = open('$LFG_DIR/lib/theme.css').read()
uijs = open('$LFG_DIR/lib/ui.js').read()
rows = '''$ROWS'''

html = '''<!DOCTYPE html>
<html><head><meta charset=\"utf-8\">
<style>''' + theme + '''</style>
</head><body>
  <div class=\"header\">
    <h1><span class=\"brand\">lfg</span> wtfs <span class=\"dim\">$DIR_DISPLAY</span></h1>
    <span class=\"meta\">$TIMESTAMP</span>
  </div>
  <div class=\"summary\">
    <div class=\"stat\" data-tip=\"Total size of $DIR_DISPLAY\"><span class=\"label\">Total Used</span><span class=\"value\">$TOTAL_HR</span></div>
    <div class=\"stat\" data-tip=\"Available disk space\"><span class=\"label\">Disk Free</span><span class=\"value accent\">$DISK_FREE</span></div>
    <div class=\"stat\" data-tip=\"$RANK directories scanned\"><span class=\"label\">Directories</span><span class=\"value\">$RANK</span></div>
  </div>
  <div class=\"guidance\">
    <strong>WTFS</strong> shows disk usage for <code>$DIR_DISPLAY</code>.
    Hover rows for details. Largest directories are at the top.
    Run <code>lfg dtf</code> to find reclaimable caches, or <code>lfg btau</code> for backups.
  </div>
  <div class=\"composition-legend\"><span class=\"legend-item\"><span class=\"legend-dot\" style=\"background:#4a9eff\"></span>Dependencies</span><span class=\"legend-item\"><span class=\"legend-dot\" style=\"background:#ffd166\"></span>Cache/Build</span><span class=\"legend-item\"><span class=\"legend-dot\" style=\"background:#06d6a0\"></span>Source</span></div>
  <table>
    <thead><tr><th>#</th><th>Directory</th><th class=\"r\">Size</th><th>Composition</th><th class=\"r\">%</th></tr></thead>
    <tbody>''' + rows + '''</tbody>
  </table>
  <div id=\"action-bar\"></div>
  <div class=\"footer\">lfg wtfs - Local File Guardian | $DIR_DISPLAY</div>
  <script>''' + uijs + '''
  LFG.init({ module: \"wtfs\", context: \"$DIR_DISPLAY\", moduleVersion: \"1.0.0\", welcome: \"Showing $RANK directories in $DIR_DISPLAY\" });
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

CHAIN_FILE="/tmp/.lfg_chain_$$"

echo "Opening viewer..."
"$VIEWER" "$HTML_FILE" "LFG WTFS - $DIR_DISPLAY" --select "$CHAIN_FILE" &
VPID=$!
disown

# Chain: if user clicks a cross-module action, launch it
(
  while kill -0 "$VPID" 2>/dev/null; do
    if [[ -s "$CHAIN_FILE" ]]; then
      SEL=$(cat "$CHAIN_FILE")
      rm -f "$CHAIN_FILE"
      case "$SEL" in
        dtf) "$LFG_DIR/lib/clean.sh" ;;
        btau) "$LFG_DIR/lib/btau.sh" --view ;;
        devdrive) "$LFG_DIR/lib/devdrive.sh" ;;
        dashboard) "$LFG_DIR/lib/dashboard.sh" ;;
      esac
      break
    fi
    sleep 0.3
  done
  rm -f "$CHAIN_FILE"
) &
disown

echo "Done."

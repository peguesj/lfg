#!/usr/bin/env bash
# lfg wtfs - Where's The Free Space (disk usage viewer with cross-module integration)
set -euo pipefail

TARGET="${1:-$HOME/Developer}"
LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HTML_FILE="$LFG_DIR/.lfg_scan.html"
VIEWER="$LFG_DIR/viewer"

source "$LFG_DIR/lib/state.sh"
lfg_state_start wtfs
lfg_state_update wtfs target "$TARGET"

echo "Scanning $TARGET..."
TMPFILE=$(mktemp)
du -d1 -k "$TARGET" 2>/dev/null | sort -rn > "$TMPFILE"

TOTAL_KB=$(head -1 "$TMPFILE" | awk '{print $1}')

ROWS=""
RANK=0
while IFS=$'\t' read -r size_kb path; do
    [[ "$path" == "$TARGET" ]] && continue
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

    ROWS+="<tr class=\"clickable\" data-tip=\"${name}: ${size} (${pct}% of total)\">
      <td class=\"rank\">${RANK}</td>
      <td class=\"name\">${name}</td>
      <td class=\"size\">${size}</td>
      <td class=\"bar-cell\"><div class=\"bar-track\"><div class=\"bar-fill\" style=\"width:${bar_w}%;background:${color}\"></div></div></td>
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
  <table>
    <thead><tr><th>#</th><th>Directory</th><th class=\"r\">Size</th><th>Usage</th><th class=\"r\">%</th></tr></thead>
    <tbody>''' + rows + '''</tbody>
  </table>
  <div id=\"action-bar\"></div>
  <div class=\"footer\">lfg wtfs - Local File Guardian | $DIR_DISPLAY</div>
  <script>''' + uijs + '''
  LFG.init({ welcome: \"Showing $RANK directories in $DIR_DISPLAY\" });
  document.getElementById(\"action-bar\").appendChild(
    LFG.createActionBar([
      { label: \"Clean Caches\", color: \"#ff8c42\", module: \"dtf\", tip: \"Open DTF to scan and clean caches\" },
      { label: \"View Backups\", color: \"#06d6a0\", module: \"btau\", tip: \"Open BTAU backup status\" },
      { label: \"Full Dashboard\", color: \"#4a9eff\", module: \"dashboard\", tip: \"Open the combined dashboard\" },
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

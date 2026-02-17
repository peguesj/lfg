#!/usr/bin/env bash
# lfg btau - Back That App Up (wrapper around yj-devdrive/btau)
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BTAU_DIR="$HOME/tools/yj-devdrive"
HTML_FILE="$LFG_DIR/.lfg_btau.html"
VIEWER="$LFG_DIR/viewer"

# Pass-through to btau CLI if args given
if [[ $# -gt 0 && "$1" != "--view" ]]; then
    export PYTHONPATH="${BTAU_DIR}:${PYTHONPATH:-}"
    exec python3 -m btau.cli "$@"
fi

# Status view mode -- show backup status in WebKit viewer
echo "Gathering backup status..."

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
MANIFEST="$HOME/.config/btau/manifest.json"

BACKUP_ROWS=""
BACKUP_COUNT=0
TOTAL_SIZE_KB=0

if [[ -f "$MANIFEST" ]]; then
    # Parse manifest entries
    while IFS= read -r line; do
        name=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('volume_name','?'))" 2>/dev/null || echo "?")
        path=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('backup_path',''))" 2>/dev/null || echo "")
        ts=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('timestamp',''))" 2>/dev/null || echo "")
        btype=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('backup_type','full'))" 2>/dev/null || echo "full")

        if [[ -n "$path" && -e "$path" ]]; then
            size_kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
            TOTAL_SIZE_KB=$((TOTAL_SIZE_KB + size_kb))
        else
            size_kb=0
        fi

        if (( size_kb >= 1048576 )); then
            size=$(awk "BEGIN{printf \"%.1f GB\", $size_kb/1048576}")
        elif (( size_kb >= 1024 )); then
            size=$(awk "BEGIN{printf \"%.1f MB\", $size_kb/1024}")
        else
            size="${size_kb} KB"
        fi

        BACKUP_COUNT=$((BACKUP_COUNT + 1))

        type_class="badge-cleaned"
        [[ "$btype" == "incremental" ]] && type_class="badge-pending"

        BACKUP_ROWS+="<tr>
          <td class=\"name\">${name}</td>
          <td class=\"size\">${size}</td>
          <td><span class=\"status-badge ${type_class}\">${btype}</span></td>
          <td class=\"meta\">${ts}</td>
        </tr>"
    done < <(python3 -c "
import json, sys
try:
    m = json.load(open('$MANIFEST'))
    history = m.get('history', [])
    for e in history[-20:]:
        print(json.dumps(e))
except Exception as e:
    print(json.dumps({'error': str(e)}), file=sys.stderr)
" 2>/dev/null)
fi

# Volumes
VOLUME_ROWS=""
while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    vol_name=$(basename "$vol")
    vol_size_kb=$(du -sk "$vol" 2>/dev/null | awk '{print $1}')
    if (( vol_size_kb >= 1048576 )); then
        vol_size=$(awk "BEGIN{printf \"%.1f GB\", $vol_size_kb/1048576}")
    elif (( vol_size_kb >= 1024 )); then
        vol_size=$(awk "BEGIN{printf \"%.1f MB\", $vol_size_kb/1024}")
    else
        vol_size="${vol_size_kb} KB"
    fi
    VOLUME_ROWS+="<tr><td class=\"name\">${vol_name}</td><td class=\"size\">${vol_size}</td></tr>"
done < <(ls -d /Volumes/*[Dd]ev* 2>/dev/null; echo "")

if (( TOTAL_SIZE_KB >= 1048576 )); then
    TOTAL_HR=$(awk "BEGIN{printf \"%.1f GB\", $TOTAL_SIZE_KB/1048576}")
elif (( TOTAL_SIZE_KB >= 1024 )); then
    TOTAL_HR=$(awk "BEGIN{printf \"%.1f MB\", $TOTAL_SIZE_KB/1024}")
else
    TOTAL_HR="${TOTAL_SIZE_KB} KB"
fi

cat > "$HTML_FILE" <<HTMLEOF
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
$(cat "$LFG_DIR/lib/theme.css")
</style>
</head>
<body>
  <div class="header">
    <h1><span class="brand">lfg</span> btau <span class="dim">Back That App Up</span></h1>
    <span class="meta">${TIMESTAMP}</span>
  </div>
  <div class="summary">
    <div class="stat"><span class="label">Backups</span><span class="value">${BACKUP_COUNT}</span></div>
    <div class="stat"><span class="label">Total Size</span><span class="value accent">${TOTAL_HR}</span></div>
  </div>

  $(if [[ -n "$VOLUME_ROWS" ]]; then
    echo '<div class="section-title">Devdrive Volumes</div>'
    echo '<table><thead><tr><th>Volume</th><th class="r">Size</th></tr></thead>'
    echo "<tbody>${VOLUME_ROWS}</tbody></table>"
  fi)

  <div class="section-title">Backup History</div>
  $(if [[ -n "$BACKUP_ROWS" ]]; then
    echo '<table><thead><tr><th>Volume</th><th class="r">Size</th><th>Type</th><th>Timestamp</th></tr></thead>'
    echo "<tbody>${BACKUP_ROWS}</tbody></table>"
  else
    echo '<div class="empty-state">No backups found. Run: lfg btau backup VOLUME</div>'
  fi)

  <div style="margin-top:16px;padding:10px 14px;background:#1c1c22;border-radius:6px;border:1px solid #2a2a34;font-size:12px;color:#6b6b78;">
    <span style="color:#06d6a0;font-weight:600">lfg btau</span> commands:
    <span style="color:#a0a0b0">discover</span> |
    <span style="color:#a0a0b0">backup VOLUME</span> |
    <span style="color:#a0a0b0">status</span> |
    <span style="color:#a0a0b0">restore ID</span> |
    <span style="color:#a0a0b0">mount</span> |
    <span style="color:#a0a0b0">unmount</span>
  </div>

  <div class="footer">lfg btau - Local File Guardian | Back That App Up</div>
</body>
</html>
HTMLEOF

echo "Opening viewer..."
"$VIEWER" "$HTML_FILE" "LFG BTAU - Backup Status" &
disown
echo "Done."

#!/usr/bin/env bash
# lfg btau - Back That App Up (wrapper around yj-devdrive/btau)
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BTAU_DIR="$HOME/tools/yj-devdrive"
VIEWER="$LFG_DIR/viewer"

source "$LFG_DIR/lib/state.sh"
LFG_MODULE="btau"
HTML_FILE="$LFG_CACHE_DIR/.lfg_btau.html"

# Pass-through to btau CLI if args given
if [[ $# -gt 0 && "$1" != "--view" ]]; then
    export PYTHONPATH="${BTAU_DIR}:${PYTHONPATH:-}"
    exec python3 -m btau.cli "$@"
fi

# Status view mode -- show backup status in WebKit viewer
lfg_state_start btau
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

python3 -c "
theme = open('$LFG_DIR/lib/theme.css').read()
uijs = open('$LFG_DIR/lib/ui.js').read()
volume_rows = '''$VOLUME_ROWS'''
backup_rows = '''$BACKUP_ROWS'''

volumes_html = ''
if volume_rows.strip():
    volumes_html = '<div class=\"section-title\">Devdrive Volumes</div><table><thead><tr><th>Volume</th><th class=\"r\">Size</th></tr></thead><tbody>' + volume_rows + '</tbody></table>'

history_html = ''
if backup_rows.strip():
    history_html = '<table><thead><tr><th>Volume</th><th class=\"r\">Size</th><th>Type</th><th>Timestamp</th></tr></thead><tbody>' + backup_rows + '</tbody></table>'
else:
    history_html = '<div class=\"empty-state\">No backups found. Run: lfg btau backup VOLUME</div>'

html = '''<!DOCTYPE html>
<html><head><meta charset=\"utf-8\">
<style>''' + theme + '''</style>
</head><body>
  <div class=\"summary\">
    <div class=\"stat\"><span class=\"label\">Backups</span><span class=\"value\">$BACKUP_COUNT</span></div>
    <div class=\"stat\"><span class=\"label\">Total Size</span><span class=\"value accent\">$TOTAL_HR</span></div>
  </div>
  ''' + volumes_html + '''
  <div class=\"section-title\">Backup History</div>
  ''' + history_html + '''
  <div id=\"action-bar\"></div>
  <div class=\"footer\">lfg btau - Local File Guardian | Back That App Up</div>
  <script>''' + uijs + '''
  LFG.init({ module: \"btau\", context: \"Back That App Up\", moduleVersion: \"2.4.0\", welcome: \"$BACKUP_COUNT backups, $TOTAL_HR total\", helpContent: \"<strong>BTAU</strong> manages backups with sparse images, incremental sync, and integrity verification.<br><br>Use <code>lfg btau discover</code> to scan for volumes, <code>lfg btau backup</code> to create a backup, <code>lfg btau restore</code> to restore.\" });
  document.getElementById(\"action-bar\").appendChild(
    LFG.createCommandPanel(\"BTAU Actions\", [
      { label: \"Discover Volumes\", desc: \"Scan for devdrive volumes\", cli: \"lfg btau discover\", module: \"btau\", action: \"run\", args: \"discover\", color: \"#06d6a0\" },
      { label: \"Show Status\", desc: \"Backup manifest status\", cli: \"lfg btau status\", module: \"btau\", action: \"run\", args: \"status\", color: \"#06d6a0\" },
      { label: \"Mount Devdrive\", desc: \"Attach sparse image\", cli: \"lfg btau mount\", module: \"btau\", action: \"run\", args: \"mount\", color: \"#4a9eff\" },
      { label: \"Unmount Devdrive\", desc: \"Safely eject volume\", cli: \"lfg btau unmount\", module: \"btau\", action: \"run\", args: \"unmount\", color: \"#ffd166\" },
      { label: \"Migrate\", desc: \"Open migrate wizard\", cli: \"lfg btau migrate\", module: \"btau\", action: \"run\", args: \"migrate\", color: \"#06d6a0\" },
      { label: \"Auto-Move (Dry Run)\", desc: \"Preview auto-move rules\", cli: \"lfg btau auto-move\", module: \"btau\", action: \"run\", args: \"auto-move\", color: \"#06d6a0\" },
      { label: \"Auto-Move (Execute)\", desc: \"Execute auto-move migrations\", cli: \"lfg btau auto-move --execute\", module: \"btau\", action: \"run\", args: \"auto-move --execute\", color: \"#ffd166\" },
      { label: \"Backup Now\", desc: \"Run backup immediately\", cli: \"lfg btau backup\", module: \"btau\", action: \"run\", args: \"backup\", color: \"#06d6a0\" },
      { label: \"Restore\", desc: \"Restore from backup\", cli: \"lfg btau restore\", module: \"btau\", action: \"run\", args: \"restore\", color: \"#ffd166\" },
      { label: \"Rebuild Forest\", desc: \"Rebuild symlink forest\", cli: \"lfg btau rebuild\", module: \"btau\", action: \"run\", args: \"rebuild\", color: \"#ff4d6a\" },
    ])
  );
  document.getElementById(\"action-bar\").appendChild(
    LFG.createActionBar([
      { label: \"Disk Usage\", color: \"#4a9eff\", onclick: function(){ LFG._postNav('navigate', {target:'wtfs'}); }, tip: \"Navigate to WTFS\" },
      { label: \"Clean Caches\", color: \"#ff8c42\", onclick: function(){ LFG._postNav('navigate', {target:'dtf'}); }, tip: \"Navigate to DTF\" },
      { label: \"Devdrive\", color: \"#c084fc\", onclick: function(){ LFG._postNav('navigate', {target:'devdrive'}); }, tip: \"Navigate to DEVDRIVE\" },
      { label: \"Full Dashboard\", color: \"#4a9eff\", onclick: function(){ LFG._postNav('navigate', {target:'dashboard'}); }, tip: \"Navigate to Dashboard\" },
    ])
  );
  </script>
</body></html>'''

open('$HTML_FILE', 'w').write(html)
"

lfg_state_done btau "backup_count=$BACKUP_COUNT" "total_size=$TOTAL_HR"

if [[ "${LFG_NO_VIEWER:-}" == "1" ]]; then
    echo "Done (headless)."
else
    CHAIN_FILE="/tmp/.lfg_chain_$$"
    echo "Opening viewer..."
    "$VIEWER" "$HTML_FILE" "LFG BTAU - Backup Status" --select "$CHAIN_FILE" &
    VPID=$!
    disown
    (
      while kill -0 "$VPID" 2>/dev/null; do
        if [[ -s "$CHAIN_FILE" ]]; then
          SEL=$(cat "$CHAIN_FILE"); rm -f "$CHAIN_FILE"
          case "$SEL" in
            wtfs) "$LFG_DIR/lib/scan.sh" ;; dtf) "$LFG_DIR/lib/clean.sh" ;; devdrive) "$LFG_DIR/lib/devdrive.sh" ;; dashboard) "$LFG_DIR/lib/dashboard.sh" ;;
          esac; break
        fi; sleep 0.3
      done; rm -f "$CHAIN_FILE"
    ) &
    disown
    echo "Done."
fi

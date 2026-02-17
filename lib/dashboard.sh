#!/usr/bin/env bash
# lfg dashboard - Combined view of all 3 modules with full UI integration
set -uo pipefail

TARGET="${1:-$HOME/Developer}"
LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HTML_FILE="$LFG_DIR/.lfg_dashboard.html"
VIEWER="$LFG_DIR/viewer"

echo "Scanning $TARGET..."

# --- WTFS: Disk usage ---
TMPFILE=$(mktemp)
du -d1 -k "$TARGET" 2>/dev/null | sort -rn > "$TMPFILE"
TOTAL_KB=$(head -1 "$TMPFILE" | awk '{print $1}')

SCAN_ROWS=""
RANK=0
while IFS=$'\t' read -r size_kb path; do
    [[ "$path" == "$TARGET" ]] && continue
    RANK=$((RANK + 1))
    name=$(basename "$path")
    if (( size_kb >= 1048576 )); then size=$(awk "BEGIN{printf \"%.1f GB\", $size_kb/1048576}")
    elif (( size_kb >= 1024 )); then size=$(awk "BEGIN{printf \"%.1f MB\", $size_kb/1024}")
    else size="${size_kb} KB"; fi
    pct=$(awk "BEGIN{printf \"%.1f\", ($size_kb/$TOTAL_KB)*100}")
    if (( $(echo "$pct > 20" | bc -l) )); then color="#ff4d6a"
    elif (( $(echo "$pct > 10" | bc -l) )); then color="#ff8c42"
    elif (( $(echo "$pct > 5" | bc -l) )); then color="#ffd166"
    elif (( $(echo "$pct > 2" | bc -l) )); then color="#06d6a0"
    else color="#4a9eff"; fi
    SCAN_ROWS+="<tr data-tip=\"${name}: ${size} (${pct}%)\"><td class=\"rank\">${RANK}</td><td class=\"name\">${name}</td><td class=\"size\">${size}</td><td class=\"bar-cell\"><div class=\"bar-track\"><div class=\"bar-fill\" style=\"width:${pct}%;background:${color}\"></div></div></td><td class=\"pct\">${pct}%</td></tr>"
done < "$TMPFILE"
rm -f "$TMPFILE"

if (( TOTAL_KB >= 1048576 )); then TOTAL_HR=$(awk "BEGIN{printf \"%.1f GB\", $TOTAL_KB/1048576}")
else TOTAL_HR=$(awk "BEGIN{printf \"%.1f MB\", $TOTAL_KB/1024}"); fi

# --- DTF: Cache scan ---
echo "Scanning caches..."
CACHE_PATHS=(
    "DEV|npm|$HOME/.npm" "DEV|uv|$HOME/.cache/uv" "DEV|Cargo|$HOME/.cargo/registry"
    "DEV|Homebrew|$HOME/Library/Caches/Homebrew" "DEV|Gradle|$HOME/.gradle/caches"
    "DEV|CocoaPods|$HOME/Library/Caches/CocoaPods" "DEV|Yarn|$HOME/Library/Caches/Yarn"
    "BUILD|Puppeteer|$HOME/.cache/puppeteer" "BUILD|Playwright|$HOME/Library/Caches/ms-playwright"
    "BUILD|Electron|$HOME/Library/Caches/electron" "BUILD|TypeScript|$HOME/Library/Caches/typescript"
    "BUILD|Prisma|$HOME/.cache/prisma" "BUILD|Turbo|$HOME/Library/Caches/turbo"
    "APP|Chrome|$HOME/Library/Caches/Google" "APP|Spotify|$HOME/Library/Caches/com.spotify.client"
    "APP|VS Code|$HOME/Library/Caches/com.microsoft.VSCode.ShipIt"
    "APP|Adobe|$HOME/Library/Caches/Adobe"
    "SYS|Xcode|$HOME/Library/Developer/Xcode/DerivedData"
    "SYS|CreativeCloud|$HOME/Library/Logs/CreativeCloud"
)
CACHE_ROWS=""
CACHE_TOTAL=0
CACHE_COUNT=0
for entry in "${CACHE_PATHS[@]}"; do
    IFS='|' read -r cat name path <<< "$entry"
    [[ ! -e "$path" ]] && continue
    size_kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
    (( size_kb == 0 )) && continue
    CACHE_TOTAL=$((CACHE_TOTAL + size_kb))
    CACHE_COUNT=$((CACHE_COUNT + 1))
    if (( size_kb >= 1048576 )); then size=$(awk "BEGIN{printf \"%.1f GB\", $size_kb/1048576}")
    elif (( size_kb >= 1024 )); then size=$(awk "BEGIN{printf \"%.1f MB\", $size_kb/1024}")
    else size="${size_kb} KB"; fi
    cat_class="cat-$(echo "$cat" | tr '[:upper:]' '[:lower:]')"
    CACHE_ROWS+="<tr data-tip=\"${name}: ${size} [${cat}]\"><td><span class=\"cat ${cat_class}\">${cat}</span></td><td class=\"name\">${name}</td><td class=\"size\">${size}</td></tr>"
done
if (( CACHE_TOTAL >= 1048576 )); then CACHE_HR=$(awk "BEGIN{printf \"%.1f GB\", $CACHE_TOTAL/1048576}")
elif (( CACHE_TOTAL >= 1024 )); then CACHE_HR=$(awk "BEGIN{printf \"%.1f MB\", $CACHE_TOTAL/1024}")
else CACHE_HR="${CACHE_TOTAL} KB"; fi

# --- BTAU: Backup status ---
echo "Checking backups..."
MANIFEST="$HOME/.config/btau/manifest.json"
BACKUP_COUNT=0
BACKUP_ROWS=""
LAST_BACKUP="Never"
if [[ -f "$MANIFEST" ]]; then
    BACKUP_COUNT=$(python3 -c "import json; m=json.load(open('$MANIFEST')); print(len(m.get('history',[])))" 2>/dev/null || echo 0)
    LAST_BACKUP=$(python3 -c "import json; m=json.load(open('$MANIFEST')); h=m.get('history',[]); print(h[-1].get('timestamp','?')[:16] if h else 'Never')" 2>/dev/null || echo "Never")
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('volume_name','?'))" 2>/dev/null || echo "?")
        ts=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('timestamp','')[:16])" 2>/dev/null || echo "")
        btype=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('backup_type','full'))" 2>/dev/null || echo "full")
        type_class="badge-cleaned"; [[ "$btype" == "incremental" ]] && type_class="badge-pending"
        BACKUP_ROWS+="<tr><td class=\"name\">${name}</td><td><span class=\"status-badge ${type_class}\">${btype}</span></td><td class=\"meta\">${ts}</td></tr>"
    done < <(python3 -c "import json; [print(json.dumps(e)) for e in json.load(open('$MANIFEST')).get('history',[])[-5:]]" 2>/dev/null)
fi

DISK_FREE=$(df -h "$TARGET" | awk 'NR==2{print $4}')
DISK_USED=$(df -h "$TARGET" | awk 'NR==2{print $5}')
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
DIR_DISPLAY=$(echo "$TARGET" | sed "s|$HOME|~|")

python3 << 'PYEOF'
import os

lfg_dir = os.environ.get("LFG_DIR", os.path.expanduser("~/tools/@yj/lfg"))
theme = open(f"{lfg_dir}/lib/theme.css").read()
uijs = open(f"{lfg_dir}/lib/ui.js").read()

scan_rows = r"""SCAN_ROWS_PLACEHOLDER"""
cache_rows = r"""CACHE_ROWS_PLACEHOLDER"""
backup_rows = r"""BACKUP_ROWS_PLACEHOLDER"""

html = f'''<!DOCTYPE html>
<html><head><meta charset="utf-8">
<style>{theme}</style>
</head><body>
  <div class="header">
    <h1><span class="brand">lfg</span> Local File Guardian</h1>
    <span class="meta">TIMESTAMP_PH</span>
  </div>
  <div class="summary">
    <div class="stat clickable" onclick="switchTab('wtfs')" data-tip="Click to view disk usage">
      <span class="label">Developer</span><span class="value">TOTAL_HR_PH</span>
    </div>
    <div class="stat clickable" onclick="switchTab('dtf')" data-tip="Click to view reclaimable caches">
      <span class="label">Reclaimable</span><span class="value warn">CACHE_HR_PH</span>
    </div>
    <div class="stat" data-tip="Available disk space">
      <span class="label">Disk Free</span><span class="value accent">DISK_FREE_PH</span>
    </div>
    <div class="stat clickable" onclick="switchTab('btau')" data-tip="Click to view backup history">
      <span class="label">Backups</span><span class="value good">BACKUP_COUNT_PH</span>
    </div>
  </div>
  <div class="nav">
    <a class="active" onclick="switchTab('wtfs')">WTFS <span class="kbd">&#x2318;1</span></a>
    <a onclick="switchTab('dtf')">DTF <span class="kbd">&#x2318;2</span></a>
    <a onclick="switchTab('btau')">BTAU <span class="kbd">&#x2318;3</span></a>
  </div>
  <div id="tab-wtfs" class="tab-content active">
    <div class="guidance"><strong>WTFS</strong> - Top directories in <code>DIR_DISPLAY_PH</code> by size. Hover rows for details.</div>
    <table><thead><tr><th>#</th><th>Directory</th><th class="r">Size</th><th>Usage</th><th class="r">%</th></tr></thead>
    <tbody>{scan_rows}</tbody></table>
  </div>
  <div id="tab-dtf" class="tab-content">
    <div class="guidance"><strong>DTF</strong> - CACHE_COUNT_PH active caches found. Run <code>lfg dtf --force</code> to clean.</div>
    <table><thead><tr><th>Cat</th><th>Cache</th><th class="r">Size</th></tr></thead>
    <tbody>{cache_rows}</tbody></table>
  </div>
  <div id="tab-btau" class="tab-content">
    <div class="guidance"><strong>BTAU</strong> - Last backup: <strong>LAST_BACKUP_PH</strong>. Run <code>lfg btau discover</code> to scan volumes.</div>
    ''' + (f'<table><thead><tr><th>Volume</th><th>Type</th><th>Timestamp</th></tr></thead><tbody>{backup_rows}</tbody></table>' if backup_rows.strip() else '<div class="empty-state">No backups found. Run: lfg btau backup VOLUME</div>') + f'''
  </div>
  <div class="footer">lfg v1.0.0 - Local File Guardian | wtfs + dtf + btau</div>
  <script>{uijs}
  LFG.init({{
    welcome: "Dashboard loaded - RANK_PH dirs, CACHE_COUNT_PH caches, BACKUP_COUNT_PH backups",
    onboarding: localStorage.getItem('lfg-onboarded') ? null : [
      {{ icon: "\\uD83D\\uDD12", title: "Welcome to LFG", desc: "Local File Guardian keeps your Mac lean. Three modules work together to scan, clean, and protect your files.", color: "#4a9eff" }},
      {{ icon: "\\uD83D\\uDD0D", title: "WTFS - Disk Usage", desc: "See where your disk space is going. Scans ~/Developer by default, showing the biggest directories first.", color: "#4a9eff" }},
      {{ icon: "\\uD83D\\uDDD1", title: "DTF - Cache Cleanup", desc: "Finds reclaimable caches across dev tools, browsers, and system. Dry run by default -- use --force to clean.", color: "#ff8c42" }},
      {{ icon: "\\uD83D\\uDCE6", title: "BTAU - Backup Manager", desc: "Manages backups with sparse images, incremental sync, and integrity verification. Bridges to yj-devdrive.", color: "#06d6a0" }},
    ],
    keyHandlers: {{}}
  }});
  function switchTab(name) {{
    document.querySelectorAll('.tab-content').forEach(t => t.classList.remove('active'));
    document.querySelectorAll('.nav a').forEach(a => a.classList.remove('active'));
    document.getElementById('tab-' + name).classList.add('active');
    document.querySelectorAll('.nav a').forEach(a => {{ if (a.textContent.toLowerCase().includes(name)) a.classList.add('active'); }});
    LFG.toast('Viewing ' + name.toUpperCase(), {{ type: 'info', duration: 1500 }});
  }}
  document.addEventListener('keydown', function(e) {{
    if (e.metaKey && e.key === '1') switchTab('wtfs');
    if (e.metaKey && e.key === '2') switchTab('dtf');
    if (e.metaKey && e.key === '3') switchTab('btau');
  }});
  </script>
</body></html>'''

html_file = os.environ.get("HTML_FILE", f"{lfg_dir}/.lfg_dashboard.html")
open(html_file, 'w').write(html)
PYEOF

# Inject shell variables into the python-generated HTML
python3 -c "
html = open('$HTML_FILE').read()
replacements = {
    'SCAN_ROWS_PLACEHOLDER': open('/dev/stdin').read(),
    'TIMESTAMP_PH': '$TIMESTAMP',
    'TOTAL_HR_PH': '$TOTAL_HR',
    'CACHE_HR_PH': '$CACHE_HR',
    'DISK_FREE_PH': '$DISK_FREE',
    'BACKUP_COUNT_PH': '$BACKUP_COUNT',
    'DIR_DISPLAY_PH': '$DIR_DISPLAY',
    'CACHE_COUNT_PH': '$CACHE_COUNT',
    'LAST_BACKUP_PH': '$LAST_BACKUP',
    'RANK_PH': '$RANK',
}
for k, v in replacements.items():
    html = html.replace(k, v)
open('$HTML_FILE', 'w').write(html)
" <<< "$SCAN_ROWS"

# Also inject cache and backup rows
python3 -c "
html = open('$HTML_FILE').read()
html = html.replace('CACHE_ROWS_PLACEHOLDER', '''$CACHE_ROWS''')
html = html.replace('BACKUP_ROWS_PLACEHOLDER', '''$BACKUP_ROWS''')
open('$HTML_FILE', 'w').write(html)
"

export LFG_DIR HTML_FILE

echo "Opening viewer..."
"$VIEWER" "$HTML_FILE" "LFG Dashboard" &
disown
echo "Done."

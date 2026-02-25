#!/usr/bin/env bash
# lfg dashboard - Combined view of all 3 modules with full UI integration
set -uo pipefail

TARGET="${1:-$HOME/Developer}"
LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$LFG_DIR/lib/state.sh"
LFG_MODULE="dashboard"
HTML_FILE="$LFG_CACHE_DIR/.lfg_dashboard.html"
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
    # Composition breakdown
    deps_kb=0; cache_kb=0
    for dp in node_modules deps vendor Pods .gradle/caches .cargo/registry venv .venv; do
        [[ -d "$path/$dp" ]] && deps_kb=$((deps_kb + $(du -sk "$path/$dp" 2>/dev/null | awk '{print $1}')))
    done
    for cp in .next dist _build target __pycache__ .turbo .cache .parcel-cache; do
        [[ -d "$path/$cp" ]] && cache_kb=$((cache_kb + $(du -sk "$path/$cp" 2>/dev/null | awk '{print $1}')))
    done
    source_kb=$((size_kb - deps_kb - cache_kb)); (( source_kb < 0 )) && source_kb=0
    if (( size_kb > 0 )); then
        d_pct=$(awk "BEGIN{printf \"%.1f\", ($deps_kb/$size_kb)*100}")
        c_pct=$(awk "BEGIN{printf \"%.1f\", ($cache_kb/$size_kb)*100}")
        s_pct=$(awk "BEGIN{printf \"%.1f\", ($source_kb/$size_kb)*100}")
    else d_pct="0"; c_pct="0"; s_pct="0"; fi
    SCAN_ROWS+="<tr data-tip=\"${name}: ${size} (${pct}%)\"><td class=\"rank\">${RANK}</td><td class=\"name\">${name}</td><td class=\"size\">${size}</td><td class=\"bar-cell\"><div class=\"bar-track segmented\" style=\"display:flex\"><div class=\"bar-seg\" style=\"width:${d_pct}%;background:#4a9eff\" data-tip=\"Deps\"></div><div class=\"bar-seg\" style=\"width:${c_pct}%;background:#ffd166\" data-tip=\"Cache\"></div><div class=\"bar-seg\" style=\"width:${s_pct}%;background:#06d6a0\" data-tip=\"Source\"></div></div></td><td class=\"pct\">${pct}%</td></tr>"
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

# --- DEVDRIVE: Profile-aware volume status ---
echo "Checking devdrive..."
source "$LFG_DIR/lib/settings.sh" 2>/dev/null
DEVDRIVE_DIR_PY="$HOME/tools/yj-devdrive"
DD_PROFILES_JSON=$(lfg_settings_get_profiles 2>/dev/null || echo '[]')
DD_VOLUME_COUNT=0
DD_PROJECT_COUNT=0
DD_HEALTHY_COUNT=0
DD_BROKEN_COUNT=0
DD_MOUNTED_COUNT=0
DD_VOLUME_ROWS=""
DD_PROJECT_ROWS=""

# Gather per-profile data
export PYTHONPATH="${DEVDRIVE_DIR_PY}:${PYTHONPATH:-}"
DD_PROFILES_DATA=$(DD_PROFILES_JSON="$DD_PROFILES_JSON" python3 << 'DDPY'
import json, os, sys
try:
    profiles = json.loads(os.environ.get('DD_PROFILES_JSON', '[]'))
except:
    profiles = []
results = []
for p in profiles:
    name = p.get('name', '')
    mount = f"/Volumes/{name}"
    mounted = os.path.isdir(mount)
    free_gb = 0; total_gb = 0; used_pct = 0
    if mounted:
        try:
            st = os.statvfs(mount)
            free_gb = round(st.f_bavail * st.f_frsize / (1024**3), 1)
            total_gb = round(st.f_blocks * st.f_frsize / (1024**3), 1)
            used_pct = round(100 * (1 - st.f_bavail / max(st.f_blocks, 1)))
        except: pass
    proj_count = 0
    if mounted:
        try:
            proj_count = len([d for d in os.listdir(mount) if os.path.isdir(os.path.join(mount, d)) and not d.startswith('.')])
        except: pass
    results.append({
        'name': name, 'purpose': p.get('purpose', ''), 'color': p.get('color', '#c084fc'),
        'mounted': mounted, 'free_gb': free_gb, 'total_gb': total_gb, 'used_pct': used_pct,
        'project_count': proj_count, 'policy': p.get('auto_move_policy', 'manual')
    })
print(json.dumps(results))
DDPY
)

# Parse profile data into shell rows
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    dd_name=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['name'])" 2>/dev/null)
    dd_mounted=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d['mounted'] else 'false')" 2>/dev/null)
    dd_free=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d['free_gb']:.1f} GB\")" 2>/dev/null)
    dd_projs=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['project_count'])" 2>/dev/null)
    dd_color=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['color'])" 2>/dev/null)
    dd_purpose=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['purpose'])" 2>/dev/null)

    DD_VOLUME_COUNT=$((DD_VOLUME_COUNT + 1))
    [[ "$dd_mounted" == "true" ]] && DD_MOUNTED_COUNT=$((DD_MOUNTED_COUNT + 1))
    DD_PROJECT_COUNT=$((DD_PROJECT_COUNT + dd_projs))

    local_status="Not Mounted"; local_class="badge-error"
    [[ "$dd_mounted" == "true" ]] && local_status="Mounted" && local_class="badge-cleaned"

    DD_VOLUME_ROWS+="<tr data-tip=\"${dd_name}: ${dd_free} free, ${dd_projs} projects\" style=\"border-left:3px solid ${dd_color}\"><td class=\"name\">${dd_name}<br><span class=\"meta\">${dd_purpose}</span></td><td><span class=\"status-badge ${local_class}\">${local_status}</span></td><td class=\"size\">${dd_free}</td><td class=\"rank\">${dd_projs}</td></tr>"
done < <(echo "$DD_PROFILES_DATA" | python3 -c "import json,sys; [print(json.dumps(p)) for p in json.load(sys.stdin)]" 2>/dev/null)

DD_STATUS="${DD_MOUNTED_COUNT}/${DD_VOLUME_COUNT} Mounted"

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

export LFG_DIR HTML_FILE

python3 << 'PYEOF'
import os

lfg_dir = os.environ.get("LFG_DIR", os.path.expanduser("~/tools/@yj/lfg"))
theme = open(f"{lfg_dir}/lib/theme.css").read()
uijs = open(f"{lfg_dir}/lib/ui.js").read()

scan_rows = r"""SCAN_ROWS_PLACEHOLDER"""
cache_rows = r"""CACHE_ROWS_PLACEHOLDER"""
backup_rows = r"""BACKUP_ROWS_PLACEHOLDER"""
dd_volume_rows = r"""DD_VOLUME_ROWS_PLACEHOLDER"""
dd_project_rows = r"""DD_PROJECT_ROWS_PLACEHOLDER"""

html = f'''<!DOCTYPE html>
<html><head><meta charset="utf-8">
<style>{theme}</style>
</head><body>
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
    <div class="stat clickable" onclick="switchTab('devdrive')" data-tip="Click to view devdrive status">
      <span class="label">Devdrive</span><span class="value" style="color:#c084fc">DD_STATUS_PH</span>
    </div>
    <div class="stat clickable" onclick="switchTab('stfu')" data-tip="Click to view project forensics">
      <span class="label">STFU</span><span class="value" id="stfu-stat" style="color:#c084fc">...</span>
    </div>
  </div>
  <div class="nav">
    <a class="active" onclick="switchTab('wtfs')">WTFS <span class="kbd">&#x2318;1</span></a>
    <a onclick="switchTab('dtf')">DTF <span class="kbd">&#x2318;2</span></a>
    <a onclick="switchTab('btau')">BTAU <span class="kbd">&#x2318;3</span></a>
    <a onclick="switchTab('devdrive')">DEVDRIVE <span class="kbd">&#x2318;4</span></a>
    <a onclick="switchTab('stfu')">STFU <span class="kbd">&#x2318;5</span></a>
  </div>
  <div class="dashboard-layout">
  <div class="main-column">
  <div id="tab-wtfs" class="tab-content active">
    <table><thead><tr><th>#</th><th>Directory</th><th class="r">Size</th><th>Usage</th><th class="r">%</th></tr></thead>
    <tbody>{scan_rows}</tbody></table>
  </div>
  <div id="tab-dtf" class="tab-content">
    <table><thead><tr><th>Cat</th><th>Cache</th><th class="r">Size</th></tr></thead>
    <tbody>{cache_rows}</tbody></table>
  </div>
  <div id="tab-btau" class="tab-content">
    ''' + (f'<table><thead><tr><th>Volume</th><th>Type</th><th>Timestamp</th></tr></thead><tbody>{backup_rows}</tbody></table>' if backup_rows.strip() else '<div class="empty-state">No backups found. Run: lfg btau backup VOLUME</div>') + f'''
  </div>
  <div id="tab-devdrive" class="tab-content">
    ''' + (f'<div class="section-title" style="color:#c084fc">Volumes</div><table><thead><tr><th>Volume</th><th class="r">Free</th><th class="r">Projects</th></tr></thead><tbody>{dd_volume_rows}</tbody></table>' if dd_volume_rows.strip() else '<div class="section-title" style="color:#c084fc">Volumes</div><div class="empty-state">No devdrive volumes detected.</div>') + f'''
    ''' + (f'<div class="section-title" style="color:#c084fc">Symlink Forest</div><table><thead><tr><th>Project</th><th>Volume</th><th>Status</th></tr></thead><tbody>{dd_project_rows}</tbody></table>' if dd_project_rows.strip() else '<div class="section-title" style="color:#c084fc">Symlink Forest</div><div class="empty-state">No projects in symlink forest.</div>') + f'''
  </div>
  <div id="tab-stfu" class="tab-content">
    <div id="stfu-main-loading" class="empty-state">Scanning project relationships...</div>
    <div id="stfu-main-duplicates" style="display:none"></div>
    <div id="stfu-main-relationships" style="display:none"></div>
    <div id="stfu-main-clusters" style="display:none"></div>
  </div>
  </div><!-- /main-column -->
  <div class="side-column">
    <div class="side-tab-nav">
      <a class="active" data-tab="stfu" onclick="LFG.switchSideTab('stfu')">Inspector <span class="kbd">&#x2318;6</span></a>
      <a data-tab="ai" onclick="LFG.switchSideTab('ai')">AI <span class="kbd">&#x2318;7</span></a>
      <a data-tab="settings" onclick="LFG.switchSideTab('settings')">Settings <span class="kbd">&#x2318;8</span></a>
    </div>
    <div id="side-stfu" class="side-panel active">
      <div class="section-title">Source Tree Forensics</div>
      <div class="empty-state" id="stfu-loading">Scanning relationships...</div>
      <div id="stfu-related" style="display:none"></div>
      <div id="stfu-duplicates" style="display:none"></div>
      <div id="stfu-clusters" style="display:none"></div>
    </div>
    <div id="side-ai" class="side-panel">
      <div id="chat-panel-container"></div>
      <div style="margin-top:12px;padding-top:8px;border-top:1px solid #2a2a34">
        <div class="setting-row"><span class="setting-label">Status</span><span id="ai-status" class="ai-pill" style="background:#6b6b78">Checking...</span></div>
        <div class="setting-row"><span class="setting-label">Model</span><span id="ai-model">--</span></div>
        <button id="ai-analyze-btn" style="margin-top:8px;width:100%;padding:7px 16px;border:1px solid #4a9eff;border-radius:6px;background:transparent;color:#4a9eff;font-size:11px;font-weight:600;cursor:pointer;font-family:inherit" class="action-btn">Analyze Selected</button>
        <div id="ai-results" style="margin-top:8px"></div>
      </div>
    </div>
    <div id="side-settings" class="side-panel">
      <div class="section-title">Scan Paths</div>
      <div id="scan-paths-list" style="margin-bottom:8px"></div>
      <div style="display:flex;gap:6px;margin-bottom:16px">
        <input id="new-path-input" class="setting-input" placeholder="/path/to/projects" style="flex:1">
        <button class="action-btn" style="padding:4px 10px;font-size:10px" onclick="var p=document.getElementById('new-path-input').value;if(p)LFG.exec('~/tools/@yj/lfg/lfg settings paths add '+p,function(o){{LFG.toast(o,{{type:'info'}});loadSettings()}})">Add</button>
      </div>

      <div class="section-title">Volume Profiles</div>
      <div id="volume-profiles-list" style="margin-bottom:8px"></div>

      <div class="section-title">Library Namespace</div>
      <div class="setting-row" style="margin-bottom:16px">
        <input id="set-namespace" class="setting-input" value="@jeremiah" style="width:100%" onchange="LFG.exec('~/tools/@yj/lfg/lfg settings set library_namespace '+this.value,function(){{LFG.toast('Namespace updated',{{type:'success'}})}})">
      </div>

      <div class="section-title">AI Settings</div>
      <div class="setting-row"><span class="setting-label">Backend</span><select id="set-backend" class="setting-input" onchange="LFG.exec('~/tools/@yj/lfg/lfg settings set ai.backend '+this.value,function(){{}})"><option value="litellm">LiteLLM Proxy</option><option value="claude">Claude (Anthropic)</option><option value="ollama">Ollama (Local)</option></select></div>
      <div class="setting-row"><span class="setting-label">Model</span><select id="set-model" class="setting-input" onchange="LFG.exec('~/tools/@yj/lfg/lfg ai config set model '+this.value,function(){{}})"><option>gpt-4o-mini</option><option>gpt-4o</option><option>claude-sonnet-4-5-20250929</option><option>ollama/llama3</option></select></div>
      <div class="setting-row"><span class="setting-label">Endpoint</span><input id="set-endpoint" class="setting-input" value="http://localhost:4000" onchange="LFG.exec('~/tools/@yj/lfg/lfg ai config set endpoint '+this.value,function(){{}})"></div>
      <div class="setting-row"><span class="setting-label">Temperature</span><input id="set-temp" type="range" min="0" max="1" step="0.1" value="0.3" class="setting-input" onchange="LFG.exec('~/tools/@yj/lfg/lfg ai config set temperature '+this.value,function(){{}})"></div>
      <div class="setting-row"><span class="setting-label">System Override</span><label class="setting-toggle"><input type="checkbox" id="set-override" onchange="LFG.exec('~/tools/@yj/lfg/lfg ai config set system_override '+(this.checked?'true':'false'),function(){{}})"><span class="toggle-slider"></span></label></div>
      <button onclick="LFG.exec('~/tools/@yj/lfg/lfg ai config show',function(out){{LFG.toast(out||'Config loaded',{{type:'info'}})}})" style="margin-top:8px;width:100%" class="action-btn">Test Connection</button>

      <div class="section-title" style="margin-top:16px">Graph Interval</div>
      <div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:16px">
        <button onclick="setGraphInterval(60,'1 min')" class="action-btn" style="padding:4px 12px;font-size:10px">1 min</button>
        <button onclick="setGraphInterval(300,'5 min')" class="action-btn" style="padding:4px 12px;font-size:10px">5 min</button>
        <button onclick="setGraphInterval(900,'15 min')" class="action-btn" style="padding:4px 12px;font-size:10px">15 min</button>
        <button onclick="setGraphInterval(1800,'30 min')" class="action-btn" style="padding:4px 12px;font-size:10px">30 min</button>
      </div>

      <div class="section-title" style="margin-top:16px">Module Access</div>
      <div id="module-access-grid" style="font-size:10px;color:#6b6b78"></div>

      <button onclick="LFG.confirm('Reset all settings to defaults?','~/tools/@yj/lfg/lfg settings reset',function(){{LFG.toast('Settings reset',{{type:'info'}});loadSettings()}})" style="margin-top:16px;width:100%" class="action-btn" style="border-color:#ff4d6a;color:#ff4d6a">Reset Defaults</button>
    </div>
  </div>
  </div><!-- /dashboard-layout -->
  <div class="footer">lfg v2.4.0 - Local File Guardian | WTFS + DTF + BTAU + DEVDRIVE + STFU + AI + Settings</div>
  <script>{uijs}
  LFG.init({{
    module: "dashboard", context: "All Modules", moduleVersion: "2.4.0",
    welcome: "Dashboard loaded - RANK_PH dirs, CACHE_COUNT_PH caches, BACKUP_COUNT_PH backups, DD_PROJECT_COUNT_PH devdrive projects",
    helpContent: "<strong>LFG Dashboard</strong><br><br><strong>WTFS</strong> - Top directories by size. Hover rows for details.<br><strong>DTF</strong> - Active caches found. Run <code>lfg dtf --force</code> to clean.<br><strong>BTAU</strong> - Backup history. Run <code>lfg btau discover</code> to scan volumes.<br><strong>DEVDRIVE</strong> - Symlink forest status. Run <code>lfg devdrive</code> for full view.<br><strong>STFU</strong> - Source Tree Forensics. Scans for project relationships and duplicates.<br><br>Use module tabs or nav pills in the header to switch views.",
    onboarding: localStorage.getItem('lfg-onboarded') ? null : [
      {{ icon: "\\uD83D\\uDD12", title: "Welcome to LFG", desc: "Local File Guardian keeps your Mac lean. Four modules work together to scan, clean, protect, and organize your files.", color: "#4a9eff" }},
      {{ icon: "\\uD83D\\uDD0D", title: "WTFS - Disk Usage", desc: "See where your disk space is going. Scans ~/Developer by default, showing the biggest directories first.", color: "#4a9eff" }},
      {{ icon: "\\uD83D\\uDDD1", title: "DTF - Cache Cleanup", desc: "Finds reclaimable caches across dev tools, browsers, and system. Dry run by default -- use --force to clean.", color: "#ff8c42" }},
      {{ icon: "\\uD83D\\uDCE6", title: "BTAU - Backup Manager", desc: "Manages backups with sparse images, incremental sync, and integrity verification. Bridges to yj-devdrive.", color: "#06d6a0" }},
      {{ icon: "\\uD83D\\uDCBE", title: "DEVDRIVE - Developer Drive", desc: "Manages symlink forests across volume profiles. Mount, sync, and verify projects from configured volume profiles.", color: "#c084fc" }},
    ],
    keyHandlers: {{}}
  }});
  function setGraphInterval(secs, label) {{
    LFG.exec('~/tools/@yj/lfg/lfg settings set graph_interval ' + secs, function(out, err, code) {{
      if (code === 0) LFG.toast('Graph interval set to ' + label, {{type:'success'}});
      else LFG.toast('Failed to set interval', {{type:'error'}});
    }});
  }}
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
    if (e.metaKey && e.key === '4') switchTab('devdrive');
    if (e.metaKey && e.key === '5') switchTab('stfu');
  }});
  // Initialize chat panel
  setTimeout(function() {{
    LFG.chat.initPanel('chat-panel-container');
    LFG.chat.isAvailable(function(ok, info) {{
      var el = document.getElementById('ai-status');
      if (el) {{
        el.textContent = ok ? 'Connected' : 'Offline';
        el.style.background = ok ? 'rgba(6,214,160,0.12)' : 'rgba(255,77,106,0.12)';
        el.style.color = ok ? '#06d6a0' : '#ff4d6a';
      }}
      var modelEl = document.getElementById('ai-model');
      if (modelEl && ok && info) modelEl.textContent = info.model || info.backend || '--';
    }});
    LFG.exec('~/tools/@yj/lfg/lfg ai config get model', function(out) {{
      var el = document.getElementById('ai-model');
      if (el && out.trim()) el.textContent = out.trim();
    }});
  }}, 1000);
  // STFU scan (populates both main tab and side inspector)
  setTimeout(function() {{
    LFG.exec('~/tools/@yj/lfg/lfg stfu --json 2>/dev/null || echo "{{}}"', function(out) {{
      try {{
        var data = JSON.parse(out || '{{}}');

        // --- Side panel (inspector) ---
        var loading = document.getElementById('stfu-loading');
        var related = document.getElementById('stfu-related');
        if (loading) loading.style.display = 'none';
        if (related && data.relationships && data.relationships.length > 0) {{
          related.style.display = 'block';
          related.innerHTML = '<div class="section-title" style="font-size:11px;margin-top:8px">Related Projects</div>' +
            data.relationships.slice(0, 8).map(function(r) {{
              return '<div class="stfu-relationship-card"><span>' + r.a + '</span><div class="stfu-score-bar"><div style="width:' + (r.score * 100) + '%;background:#c084fc"></div></div><span>' + r.b + '</span></div>';
            }}).join('');
        }}

        // --- Main tab ---
        var mainLoading = document.getElementById('stfu-main-loading');
        if (mainLoading) mainLoading.style.display = 'none';

        // Duplicates table
        var dupes = document.getElementById('stfu-main-duplicates');
        if (dupes && data.duplicates && data.duplicates.length > 0) {{
          dupes.style.display = 'block';
          dupes.innerHTML = '<div class="section-title" style="color:#ff4d6a">Possible Duplicates (' + data.duplicates.length + ')</div>' +
            '<table><thead><tr><th>Project A</th><th>Project B</th><th class="r">Score</th><th>Shared</th></tr></thead><tbody>' +
            data.duplicates.map(function(d) {{
              var pct = Math.round(d.score * 100);
              var color = pct > 80 ? '#ff4d6a' : '#ff8c42';
              return '<tr data-tip="' + d.shared_deps.slice(0,5).join(', ') + '"><td class="name">' + d.a + '</td><td class="name">' + d.b + '</td><td class="pct" style="color:' + color + '">' + pct + '%</td><td class="meta">' + d.shared_deps.length + ' deps</td></tr>';
            }}).join('') + '</tbody></table>';
        }}

        // Relationships table
        var rels = document.getElementById('stfu-main-relationships');
        if (rels && data.relationships && data.relationships.length > 0) {{
          rels.style.display = 'block';
          rels.innerHTML = '<div class="section-title" style="color:#c084fc">All Relationships (' + data.relationships.length + ')</div>' +
            '<table><thead><tr><th>Project A</th><th>Project B</th><th>Similarity</th><th>Stack</th></tr></thead><tbody>' +
            data.relationships.map(function(r) {{
              var pct = Math.round(r.score * 100);
              return '<tr data-tip="' + r.shared_deps.slice(0,5).join(', ') + '"><td class="name">' + r.a + '</td><td class="name">' + r.b + '</td><td class="bar-cell"><div class="bar-track"><div class="bar-fill" style="width:' + pct + '%;background:#c084fc"></div></div></td><td class="meta">' + (r.shared_stack || []).join(', ') + '</td></tr>';
            }}).join('') + '</tbody></table>';
        }}

        // Clusters
        var clusters = document.getElementById('stfu-main-clusters');
        if (clusters && data.clusters && data.clusters.length > 0) {{
          clusters.style.display = 'block';
          clusters.innerHTML = '<div class="section-title" style="color:#06d6a0">Coalescence Clusters (' + data.clusters.length + ')</div>' +
            data.clusters.map(function(c, i) {{
              return '<div style="margin-bottom:12px;padding:10px 14px;background:#1c1c22;border:1px solid #2a2a34;border-radius:8px;border-left:3px solid #06d6a0"><div style="font-size:10px;text-transform:uppercase;letter-spacing:0.8px;color:#06d6a0;margin-bottom:6px">Cluster ' + (i+1) + ' (' + c.length + ' projects)</div><div style="display:flex;flex-wrap:wrap;gap:6px">' +
                c.map(function(name) {{ return '<span class="ai-pill" style="background:#06d6a020;color:#06d6a0;border:1px solid #06d6a033">' + name + '</span>'; }}).join('') +
              '</div></div>';
            }}).join('');
        }}

        // Summary stat
        var statEl = document.getElementById('stfu-stat');
        if (statEl) statEl.textContent = (data.duplicates||[]).length + ' dupes';
        LFG.toast('STFU: ' + (data.project_count||0) + ' projects, ' + (data.relationships||[]).length + ' relationships, ' + (data.duplicates||[]).length + ' duplicates', {{type:'info', duration:3000}});
      }} catch(e) {{
        var ml = document.getElementById('stfu-main-loading');
        if (ml) ml.textContent = 'Error loading STFU data';
        var sl = document.getElementById('stfu-loading');
        if (sl) sl.textContent = 'Error loading data';
      }}
    }});
  }}, 1500);
  // Analyze button
  var abtn = document.getElementById('ai-analyze-btn');
  if (abtn) abtn.onclick = function() {{
    var active = document.querySelector('#tab-wtfs tr.selected .name, #tab-wtfs tr:first-child .name');
    var name = active ? active.textContent : '';
    if (!name) {{ LFG.toast('Select a project first', {{type:'warning'}}); return; }}
    LFG.ai.analyze(name, function(result) {{
      var el = document.getElementById('ai-results');
      if (el) el.innerHTML = '<div class="ai-pill">' + (result.purpose || result.error || 'Unknown') + '</div>';
    }});
  }};

  // Settings panel: load and render scan paths + module access
  function loadSettings() {{
    LFG.exec('~/tools/@yj/lfg/lfg settings show --json', function(out) {{
      try {{
        var s = JSON.parse(out);
        // Scan paths
        var pathsEl = document.getElementById('scan-paths-list');
        if (pathsEl && s.scan_paths) {{
          pathsEl.innerHTML = s.scan_paths.map(function(p) {{
            return '<div style="display:flex;justify-content:space-between;align-items:center;padding:4px 8px;margin-bottom:4px;background:#1c1c22;border:1px solid #2a2a34;border-radius:4px"><span style="font-size:11px;color:#d0d0d8;font-family:monospace">' + p + '</span><button class="action-btn-sm" style="padding:2px 6px;font-size:9px;border-color:#ff4d6a;color:#ff4d6a" onclick="LFG.confirm(\\'Remove ' + p + '?\\',\\'~/tools/@yj/lfg/lfg settings paths remove ' + p + '\\',function(){{loadSettings()}})">x</button></div>';
          }}).join('');
        }}
        // Volume profiles
        var vpEl = document.getElementById('volume-profiles-list');
        if (vpEl && s.volume_profiles) {{
          vpEl.innerHTML = s.volume_profiles.map(function(p, i) {{
            var mounted = p.mounted ? '<span style="color:#06d6a0;font-size:9px">MOUNTED</span>' : '<span style="color:#6b6b78;font-size:9px">NOT MOUNTED</span>';
            var colorSwatch = '<span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:' + (p.color||'#c084fc') + ';margin-right:6px"></span>';
            return '<div style="padding:8px;margin-bottom:6px;background:#1c1c22;border:1px solid #2a2a34;border-radius:6px;border-left:3px solid ' + (p.color||'#c084fc') + '">' +
              '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:4px">' + colorSwatch + '<strong style="font-size:11px;color:#d0d0d8">' + (p.name||'') + '</strong>' + mounted + '</div>' +
              '<div style="font-size:10px;color:#6b6b78;margin-bottom:2px">' + (p.purpose||'') + '</div>' +
              '<div style="font-size:10px;color:#6b6b78">' + (p.system_link||'') + '</div>' +
              '</div>';
          }}).join('');
        }}
        // Namespace
        var nsEl = document.getElementById('set-namespace');
        if (nsEl && s.library_namespace) nsEl.value = s.library_namespace;
        // Module access
        var accessEl = document.getElementById('module-access-grid');
        if (accessEl && s.module_access) {{
          var modules = Object.keys(s.module_access);
          accessEl.innerHTML = modules.map(function(m) {{
            var val = s.module_access[m];
            return '<div style="display:flex;justify-content:space-between;padding:2px 0"><span>' + m + '</span><span style="color:#06d6a0">' + val + '</span></div>';
          }}).join('');
        }}
      }} catch(e) {{}}
    }});
  }}
  // Auto-load settings when Settings tab is shown
  document.querySelectorAll('.side-tab-nav a').forEach(function(a) {{
    a.addEventListener('click', function() {{ if (this.textContent.indexOf('Settings') !== -1) loadSettings(); }});
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
    'DD_STATUS_PH': '$DD_STATUS',
    'DD_VOLUME_COUNT_PH': '$DD_VOLUME_COUNT',
    'DD_PROJECT_COUNT_PH': '$DD_PROJECT_COUNT',
}
for k, v in replacements.items():
    html = html.replace(k, v)
open('$HTML_FILE', 'w').write(html)
" <<< "$SCAN_ROWS"

# Also inject cache, backup, and devdrive rows
python3 -c "
html = open('$HTML_FILE').read()
html = html.replace('CACHE_ROWS_PLACEHOLDER', '''$CACHE_ROWS''')
html = html.replace('BACKUP_ROWS_PLACEHOLDER', '''$BACKUP_ROWS''')
html = html.replace('DD_VOLUME_ROWS_PLACEHOLDER', '''$DD_VOLUME_ROWS''')
html = html.replace('DD_PROJECT_ROWS_PLACEHOLDER', '''$DD_PROJECT_ROWS''')
open('$HTML_FILE', 'w').write(html)
"

if [[ "${LFG_NO_VIEWER:-}" == "1" ]]; then
    echo "Done (headless)."
else
    echo "Opening viewer..."
    "$VIEWER" "$HTML_FILE" "LFG Dashboard" &
    disown
    echo "Done."
fi

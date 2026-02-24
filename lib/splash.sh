#!/usr/bin/env bash
# lfg splash - Clean home screen with icon rail + disk bar + module tiles
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$LFG_DIR/lib/state.sh"
LFG_MODULE="splash"
HTML_FILE="$LFG_CACHE_DIR/.lfg_splash.html"
VIEWER="$LFG_DIR/viewer"

# Gather live disk stats (APFS-aware: calculate used from total * capacity%)
DISK_INFO=$(df / | awk 'NR==2{
  total_gb = int($2 * 512 / 1e9 + 0.5)
  pct = $5 + 0
  used_gb = int(total_gb * pct / 100 + 0.5)
  avail_gb = $4 * 512 / 1e9
  printf "%d|%d|%.1f|%d\n", total_gb, used_gb, avail_gb, pct
}')
DISK_TOTAL=$(echo "$DISK_INFO" | cut -d'|' -f1)" GB"
DISK_USED_AMT=$(echo "$DISK_INFO" | cut -d'|' -f2)" GB"
DISK_FREE=$(echo "$DISK_INFO" | cut -d'|' -f3)" GB"
DISK_USED_PCT=$(echo "$DISK_INFO" | cut -d'|' -f4)
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")

# Read state.json for module status
STATE_FILE="$HOME/.config/lfg/state.json"
STATE_JSON="{}"
[[ -f "$STATE_FILE" ]] && STATE_JSON=$(cat "$STATE_FILE")

export LFG_DIR HTML_FILE DISK_TOTAL DISK_USED_AMT DISK_FREE DISK_USED_PCT TIMESTAMP STATE_JSON LFG_CACHE_DIR

python3 << 'PYEOF'
import json, os, sys

lfg_dir = os.environ.get("LFG_DIR", os.path.expanduser("~/tools/@yj/lfg"))
html_file = os.environ.get("HTML_FILE", lfg_dir + "/.lfg_splash.html")
disk_total = os.environ.get("DISK_TOTAL", "?")
disk_used_amt = os.environ.get("DISK_USED_AMT", "?")
disk_free = os.environ.get("DISK_FREE", "?")
disk_used_pct = int(os.environ.get("DISK_USED_PCT", "0"))
timestamp = os.environ.get("TIMESTAMP", "")
lfg_cache_dir = os.environ.get("LFG_CACHE_DIR", lfg_dir)

# Load state
try:
    state = json.loads(os.environ.get("STATE_JSON", "{}"))
except:
    state = {}

modules = state.get("modules", {})

# Build module status summaries
def mod_summary(name):
    m = modules.get(name, {})
    status = m.get("status", "idle")
    if name == "wtfs":
        return m.get("total_size", "--"), m.get("dir_count", "--"), status
    elif name == "dtf":
        return m.get("reclaimable", m.get("freed", "--")), m.get("mode", "scan"), status
    elif name == "btau":
        return m.get("backup_count", "0"), m.get("total_size", "--"), status
    elif name == "devdrive":
        return m.get("project_count", "--"), m.get("volume_count", "--"), status
    elif name == "stfu":
        return m.get("projects", "--"), "", status
    return "--", "--", status

wtfs = mod_summary("wtfs")
dtf = mod_summary("dtf")
btau = mod_summary("btau")
dd = mod_summary("devdrive")
stfu = mod_summary("stfu")

theme_css = open(lfg_dir + "/lib/theme.css").read()
ui_js = open(lfg_dir + "/lib/ui.js").read()

# Disk bar color
if disk_used_pct > 90:
    bar_color = "#ff4d6a"
    bar_bg = "rgba(255,77,106,0.15)"
elif disk_used_pct > 80:
    bar_color = "#ffd166"
    bar_bg = "rgba(255,209,102,0.12)"
elif disk_used_pct > 70:
    bar_color = "#8dcfff"
    bar_bg = "rgba(141,207,255,0.12)"
else:
    bar_color = "#4a9eff"
    bar_bg = "rgba(74,158,255,0.1)"

# Status dot color
def status_dot(s):
    if s == "running": return "#ffd166"
    if s == "completed": return "#4a9eff"
    if s == "error": return "#ff4d6a"
    return "#3a3a44"

# Tooltip text per module
tooltip_wtfs = f"Where's The Free Space -- Last: {wtfs[0]} across {wtfs[1]} dirs"
tooltip_dtf = f"Delete Temp Files -- {dtf[0]} reclaimable ({dtf[1]} mode)"
tooltip_btau = f"Back That App Up -- {btau[0]} backups, {btau[1]} total"
tooltip_dd = f"Developer Drive -- {dd[0]} projects, {dd[1]} volumes"
tooltip_stfu = f"Source Tree Forensics -- {stfu[0]}"
tooltip_ai = "AI Engine -- Combined module intelligence"

html = f'''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
{theme_css}

:root {{
  --accent: #4a9eff;
  --bg: #141418;
  --surface: #1c1c22;
  --border: #2a2a34;
  --text-dim: #6b6b78;
  --text-mid: #a0a0b0;
  --spring: cubic-bezier(0.22, 1, 0.36, 1);
}}

body {{
  user-select: none;
}}

/* === MAIN CONTENT === */
.main {{
  display: flex;
  flex-direction: column;
  min-height: calc(100vh - 48px);
  padding: 20px 36px 24px;
  animation: fadeIn 0.4s ease-out;
}}
@keyframes fadeIn {{
  from {{ opacity: 0; transform: translateY(8px); }}
  to {{ opacity: 1; transform: translateY(0); }}
}}

/* Greeting */
.greeting {{
  font-size: 24px;
  font-weight: 700;
  color: #fff;
  letter-spacing: -0.5px;
  margin-bottom: 4px;
}}
.greeting span {{ color: var(--accent); }}
.greeting-sub {{
  font-size: 12px;
  color: var(--text-dim);
  margin-bottom: 40px;
}}

/* === DISK BAR === */
.disk-bar-wrap {{
  margin-bottom: 48px;
}}
.disk-bar-track {{
  width: 100%;
  height: 10px;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 5px;
  overflow: hidden;
  margin-bottom: 8px;
}}
.disk-bar-fill {{
  height: 100%;
  background: {bar_color};
  border-radius: 5px;
  width: {disk_used_pct}%;
  transition: width 0.6s var(--spring);
  box-shadow: 0 0 8px {bar_bg};
}}
.disk-bar-labels {{
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 12px;
  color: var(--text-mid);
}}
.disk-bar-labels .pct {{
  font-weight: 700;
  color: {bar_color};
}}
.disk-bar-labels .free {{
  color: var(--text-dim);
}}

/* Watermark */
.watermark {{
  font-size: 180px;
  font-weight: 900;
  letter-spacing: -6px;
  color: rgba(255,255,255,0.03);
  text-align: center;
  margin-top: auto;
  margin-bottom: 8px;
  line-height: 1;
  pointer-events: none;
}}
.watermark span {{ color: rgba(74,158,255,0.05); }}

/* === FOOTER === */
.splash-footer {{
  margin-top: auto;
  padding-top: 24px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 10px;
  color: #3a3a44;
}}
.splash-footer a {{
  color: var(--accent);
  text-decoration: none;
}}
.splash-footer a:hover {{ text-decoration: underline; }}
</style>
</head>
<body>

  <!-- MAIN CONTENT (header injected by LFG.init) -->
  <main class="main">
    <div class="greeting">Welcome to <span>LFG</span></div>
    <div class="greeting-sub">Local File Guardian &middot; {timestamp}</div>

    <!-- DISK BAR -->
    <div class="disk-bar-wrap">
      <div class="disk-bar-track">
        <div class="disk-bar-fill"></div>
      </div>
      <div class="disk-bar-labels">
        <span>{disk_used_amt} used of {disk_total} (<span class="pct">{disk_used_pct}%</span>)</span>
        <span class="free">{disk_free} free</span>
      </div>
    </div>

    <div class="watermark">L<span>F</span>G</div>

    <!-- FOOTER -->
    <div class="splash-footer">
      <span>lfg v2.4.0 &middot; @yj tools</span>
      <span><a href="http://localhost:3031" target="_blank">APM</a></span>
    </div>
  </main>

  <script>
{ui_js}

LFG.init({{
  context: "Home",
  moduleVersion: "2.4.0",
  helpContent: "<strong>LFG Home</strong><br><br>Navigate modules using the <strong>nav pills</strong> in the header bar, or use keyboard shortcuts:<br><br><code>&#8984;1</code> WTFS &mdash; Disk usage analysis<br><code>&#8984;2</code> DTF &mdash; Cache cleanup<br><code>&#8984;3</code> BTAU &mdash; Backup manager<br><code>&#8984;4</code> DEVDRIVE &mdash; Developer drive<br><code>&#8984;5</code> STFU &mdash; Source tree forensics<br><code>&#8984;6</code> Chat &mdash; AI chat<br><code>&#8984;D</code> Dashboard &mdash; Combined view<br><br>Press <code>?</code> anytime to open this help."
}});
LFG.notifications.add('Cache: {lfg_cache_dir}', 'info');
  </script>
</body>
</html>'''

with open(html_file, 'w') as f:
    f.write(html)
PYEOF

# Launch viewer (navigation happens in-process)
"$VIEWER" "$HTML_FILE" "LFG - Local File Guardian" &
disown
echo "LFG launched."

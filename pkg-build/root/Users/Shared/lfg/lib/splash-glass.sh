#!/usr/bin/env bash
# lfg splash - Liquid Glass theme (Apple-inspired glassmorphism)
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HTML_FILE="$LFG_DIR/.lfg_splash.html"
VIEWER="$LFG_DIR/viewer"

DISK_INFO=$(df -h / | awk 'NR==2{print $2 "|" $3 "|" $4 "|" $5}')
DISK_TOTAL=$(echo "$DISK_INFO" | cut -d'|' -f1)
DISK_USED_AMT=$(echo "$DISK_INFO" | cut -d'|' -f2)
DISK_FREE=$(echo "$DISK_INFO" | cut -d'|' -f3)
DISK_USED_PCT=$(echo "$DISK_INFO" | cut -d'|' -f4 | tr -d '%')
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")

STATE_FILE="$HOME/.config/lfg/state.json"
STATE_JSON="{}"
[[ -f "$STATE_FILE" ]] && STATE_JSON=$(cat "$STATE_FILE")

export LFG_DIR HTML_FILE DISK_TOTAL DISK_USED_AMT DISK_FREE DISK_USED_PCT TIMESTAMP STATE_JSON

python3 << 'PYEOF'
import json, os

lfg_dir = os.environ.get("LFG_DIR", os.path.expanduser("~/tools/@yj/lfg"))
html_file = os.environ.get("HTML_FILE", lfg_dir + "/.lfg_splash.html")
disk_total = os.environ.get("DISK_TOTAL", "?")
disk_used_amt = os.environ.get("DISK_USED_AMT", "?")
disk_free = os.environ.get("DISK_FREE", "?")
disk_used_pct = int(os.environ.get("DISK_USED_PCT", "0"))
timestamp = os.environ.get("TIMESTAMP", "")

try:
    state = json.loads(os.environ.get("STATE_JSON", "{}"))
except:
    state = {}

modules = state.get("modules", {})

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

ui_js = open(lfg_dir + "/lib/ui.js").read()

# Disk bar color
if disk_used_pct > 90:
    bar_color = "#ff6b81"
    bar_glow = "rgba(255,107,129,0.4)"
elif disk_used_pct > 80:
    bar_color = "#ffd166"
    bar_glow = "rgba(255,209,102,0.35)"
elif disk_used_pct > 70:
    bar_color = "#8dcfff"
    bar_glow = "rgba(141,207,255,0.3)"
else:
    bar_color = "#6cb4ff"
    bar_glow = "rgba(108,180,255,0.3)"

def status_dot(s):
    if s == "running": return "#ffd166"
    if s == "completed": return "#6cb4ff"
    if s == "error": return "#ff6b81"
    return "rgba(255,255,255,0.15)"

tooltip_wtfs = f"Where's The Free Space -- Last: {wtfs[0]} across {wtfs[1]} dirs"
tooltip_dtf = f"Delete Temp Files -- {dtf[0]} reclaimable ({dtf[1]} mode)"
tooltip_btau = f"Back That App Up -- {btau[0]} backups, {btau[1]} total"
tooltip_dd = f"Developer Drive -- {dd[0]} projects, {dd[1]} volumes"
tooltip_stfu = f"Source Tree Forensics -- {stfu[0]}"

html = f'''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
@font-face {{
  font-family: 'SF';
  src: local('-apple-system'), local('BlinkMacSystemFont'), local('SF Pro Display');
}}

:root {{
  --rail-w: 60px;
  --accent: #6cb4ff;
  --accent-glow: rgba(108,180,255,0.25);
  --glass-bg: rgba(255,255,255,0.06);
  --glass-bg-hover: rgba(255,255,255,0.10);
  --glass-border: rgba(255,255,255,0.10);
  --glass-border-hover: rgba(255,255,255,0.20);
  --glass-highlight: rgba(255,255,255,0.08);
  --blur: 24px;
  --blur-heavy: 40px;
  --text: rgba(255,255,255,0.92);
  --text-secondary: rgba(255,255,255,0.55);
  --text-tertiary: rgba(255,255,255,0.30);
  --spring: cubic-bezier(0.22, 1, 0.36, 1);
  --ease: cubic-bezier(0.4, 0, 0.2, 1);
}}

* {{ margin: 0; padding: 0; box-sizing: border-box; }}

/* Override platform chrome from theme.css/ui.js */
#lfg-sticky-header, #lfg-sticky-footer {{ display: none !important; }}
body {{ padding: 0 !important; }}

body {{
  font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
  overflow: hidden;
  display: flex;
  min-height: 100vh;
  user-select: none;
  /* Animated mesh gradient background */
  background: #0a0a12;
  position: relative;
}}

/* Animated background blobs for glass to refract */
body::before {{
  content: '';
  position: fixed;
  top: -20%; left: -20%;
  width: 140%; height: 140%;
  background:
    radial-gradient(ellipse 600px 400px at 20% 30%, rgba(108,180,255,0.12) 0%, transparent 70%),
    radial-gradient(ellipse 500px 500px at 75% 60%, rgba(140,100,255,0.08) 0%, transparent 70%),
    radial-gradient(ellipse 400px 300px at 50% 80%, rgba(80,200,180,0.06) 0%, transparent 70%),
    radial-gradient(ellipse 300px 400px at 85% 20%, rgba(255,140,200,0.05) 0%, transparent 70%);
  animation: bgShift 20s ease-in-out infinite alternate;
  z-index: 0;
  pointer-events: none;
}}
@keyframes bgShift {{
  0% {{ transform: translate(0, 0) scale(1); }}
  33% {{ transform: translate(-3%, 2%) scale(1.02); }}
  66% {{ transform: translate(2%, -1%) scale(0.98); }}
  100% {{ transform: translate(-1%, 3%) scale(1.01); }}
}}

/* Subtle noise texture overlay */
body::after {{
  content: '';
  position: fixed;
  inset: 0;
  background: url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='0.03'/%3E%3C/svg%3E");
  z-index: 0;
  pointer-events: none;
  opacity: 0.5;
}}

/* === GLASS RAIL === */
.rail {{
  width: var(--rail-w);
  min-height: 100vh;
  background: rgba(255,255,255,0.04);
  -webkit-backdrop-filter: blur(var(--blur-heavy)) saturate(180%);
  backdrop-filter: blur(var(--blur-heavy)) saturate(180%);
  border-right: 1px solid var(--glass-border);
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 48px 0 16px;
  gap: 4px;
  z-index: 10;
  flex-shrink: 0;
  position: relative;
}}
/* Specular highlight on rail left edge */
.rail::before {{
  content: '';
  position: absolute;
  top: 0; left: 0;
  width: 1px; height: 100%;
  background: linear-gradient(180deg,
    rgba(255,255,255,0) 0%,
    rgba(255,255,255,0.08) 30%,
    rgba(255,255,255,0.04) 70%,
    rgba(255,255,255,0) 100%);
}}

.rail-logo {{
  margin-bottom: 20px;
  opacity: 0.8;
  transition: opacity 0.2s;
}}
.rail-logo:hover {{ opacity: 1; }}

.rail-item {{
  width: 42px; height: 42px;
  display: flex; align-items: center; justify-content: center;
  border-radius: 12px;
  cursor: pointer;
  transition: all 0.25s var(--spring);
  position: relative;
  flex-shrink: 0;
}}
.rail-item:hover {{
  background: var(--glass-bg-hover);
  transform: scale(1.1);
  box-shadow: 0 0 16px rgba(108,180,255,0.08);
}}
.rail-item svg {{
  width: 20px; height: 20px;
  stroke-width: 1.6;
  stroke: rgba(255,255,255,0.4);
  fill: none;
  stroke-linecap: round;
  stroke-linejoin: round;
  transition: all 0.2s;
}}
.rail-item:hover svg {{
  stroke: rgba(255,255,255,0.9);
  filter: drop-shadow(0 0 4px var(--accent-glow));
}}

/* Rail tooltips - glass style */
.rail-item::after {{
  content: attr(data-label);
  position: absolute;
  left: 54px;
  background: rgba(20,20,30,0.85);
  -webkit-backdrop-filter: blur(16px) saturate(160%);
  backdrop-filter: blur(16px) saturate(160%);
  border: 1px solid rgba(255,255,255,0.1);
  color: var(--text);
  font-size: 11px;
  font-weight: 500;
  padding: 6px 12px;
  border-radius: 8px;
  white-space: nowrap;
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.2s, transform 0.2s var(--spring);
  transform: translateX(-6px);
  z-index: 20;
  box-shadow: 0 4px 16px rgba(0,0,0,0.3);
}}
.rail-item:hover::after {{
  opacity: 1;
  transform: translateX(0);
}}

.rail-sep {{
  width: 28px; height: 1px;
  background: linear-gradient(90deg, transparent, rgba(255,255,255,0.08), transparent);
  margin: 10px 0;
  flex-shrink: 0;
}}

.rail-bottom {{
  margin-top: auto;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
}}

.rail-dot {{
  position: absolute;
  top: 7px; right: 7px;
  width: 6px; height: 6px;
  border-radius: 50%;
  box-shadow: 0 0 4px currentColor;
}}

/* === MAIN CONTENT === */
.main {{
  flex: 1;
  display: flex;
  flex-direction: column;
  padding: 48px 64px 64px;
  overflow-y: auto;
  z-index: 1;
  animation: fadeIn 0.6s var(--ease);
}}
@keyframes fadeIn {{
  from {{ opacity: 0; transform: translateY(12px); }}
  to {{ opacity: 1; transform: translateY(0); }}
}}

/* Greeting */
.greeting {{
  font-size: 26px;
  font-weight: 700;
  color: var(--text);
  letter-spacing: -0.5px;
  margin-bottom: 4px;
}}
.greeting span {{
  background: linear-gradient(135deg, #6cb4ff, #a78bfa);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
}}
.greeting-sub {{
  font-size: 12px;
  color: var(--text-secondary);
  margin-bottom: 44px;
  font-weight: 400;
}}

/* === GLASS DISK BAR === */
.disk-bar-wrap {{
  margin-bottom: 48px;
  padding: 20px 24px;
  background: var(--glass-bg);
  -webkit-backdrop-filter: blur(var(--blur)) saturate(180%);
  backdrop-filter: blur(var(--blur)) saturate(180%);
  border: 1px solid var(--glass-border);
  border-radius: 16px;
  position: relative;
  overflow: hidden;
  box-shadow: 0 4px 24px rgba(0,0,0,0.15),
              inset 0 1px 0 var(--glass-highlight);
}}
/* Top specular edge */
.disk-bar-wrap::before {{
  content: '';
  position: absolute;
  top: 0; left: 10%; right: 10%;
  height: 1px;
  background: linear-gradient(90deg, transparent, rgba(255,255,255,0.15), transparent);
}}

.disk-bar-track {{
  width: 100%;
  height: 8px;
  background: rgba(255,255,255,0.06);
  border-radius: 4px;
  overflow: hidden;
  margin-bottom: 10px;
  position: relative;
}}
.disk-bar-fill {{
  height: 100%;
  background: linear-gradient(90deg, {bar_color}, {bar_color}cc);
  border-radius: 4px;
  width: {disk_used_pct}%;
  transition: width 0.8s var(--spring);
  box-shadow: 0 0 12px {bar_glow};
  position: relative;
}}
/* Animated shimmer on fill */
.disk-bar-fill::after {{
  content: '';
  position: absolute;
  top: 0; left: -100%; width: 100%; height: 100%;
  background: linear-gradient(90deg, transparent, rgba(255,255,255,0.2), transparent);
  animation: shimmer 3s ease-in-out infinite;
}}
@keyframes shimmer {{
  0% {{ left: -100%; }}
  100% {{ left: 200%; }}
}}

.disk-bar-labels {{
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 12px;
  color: var(--text-secondary);
  font-weight: 400;
}}
.disk-bar-labels .pct {{
  font-weight: 600;
  color: {bar_color};
  text-shadow: 0 0 8px {bar_glow};
}}
.disk-bar-labels .free {{
  color: var(--text-tertiary);
}}

/* === GLASS WATERMARK === */
.watermark {{
  font-size: 200px;
  font-weight: 900;
  letter-spacing: -10px;
  text-align: center;
  margin-top: auto;
  margin-bottom: 0;
  line-height: 1;
  pointer-events: none;
  color: rgba(255,255,255,0.025);
  text-shadow: 0 0 80px rgba(108,180,255,0.03);
}}
.watermark span {{
  color: rgba(108,180,255,0.04);
}}

/* === GLASS FOOTER === */
.splash-footer {{
  padding-top: 20px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-size: 10px;
  color: var(--text-tertiary);
  font-weight: 400;
}}
.splash-footer a {{
  color: var(--accent);
  text-decoration: none;
  opacity: 0.7;
  transition: opacity 0.15s;
}}
.splash-footer a:hover {{ opacity: 1; text-decoration: none; }}
</style>
</head>
<body>
  <!-- GLASS RAIL -->
  <nav class="rail">
    <div class="rail-logo">
      <svg viewBox="0 0 24 24" width="24" height="24" stroke="rgba(255,255,255,0.7)" fill="none" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
        <path d="M12 2L4 6v6c0 5.5 3.8 10.7 8 12 4.2-1.3 8-6.5 8-12V6z"/>
        <circle cx="12" cy="11" r="3" stroke="{bar_color}" stroke-width="1.5"/>
      </svg>
    </div>

    <div class="rail-item" data-label="WTFS  &#8984;1" onclick="nav('wtfs')">
      <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/><line x1="11" y1="8" x2="11" y2="14"/><line x1="8" y1="11" x2="14" y2="11"/></svg>
      <div class="rail-dot" style="background:{status_dot(wtfs[2])};color:{status_dot(wtfs[2])}"></div>
    </div>

    <div class="rail-item" data-label="DTF  &#8984;2" onclick="nav('dtf')">
      <svg viewBox="0 0 24 24"><polyline points="3 6 5 6 6 6"/><line x1="10" y1="12" x2="21" y2="12"/><line x1="10" y1="6" x2="21" y2="6"/><line x1="10" y1="18" x2="21" y2="18"/><path d="M3 12l2 2 4-4"/><path d="M3 18l2 2 4-4"/></svg>
      <div class="rail-dot" style="background:{status_dot(dtf[2])};color:{status_dot(dtf[2])}"></div>
    </div>

    <div class="rail-item" data-label="BTAU  &#8984;3" onclick="nav('btau')">
      <svg viewBox="0 0 24 24"><path d="M12 2v4"/><path d="M12 18v4"/><path d="M4.93 4.93l2.83 2.83"/><path d="M16.24 16.24l2.83 2.83"/><path d="M2 12h4"/><path d="M18 12h4"/><circle cx="12" cy="12" r="4"/></svg>
      <div class="rail-dot" style="background:{status_dot(btau[2])};color:{status_dot(btau[2])}"></div>
    </div>

    <div class="rail-item" data-label="DEVDRIVE  &#8984;4" onclick="nav('devdrive')">
      <svg viewBox="0 0 24 24"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M21 12c0 1.66-4 3-9 3s-9-1.34-9-3"/><path d="M3 5v14c0 1.66 4 3 9 3s9-1.34 9-3V5"/></svg>
      <div class="rail-dot" style="background:{status_dot(dd[2])};color:{status_dot(dd[2])}"></div>
    </div>

    <div class="rail-item" data-label="STFU  &#8984;5" onclick="nav('stfu')">
      <svg viewBox="0 0 24 24"><path d="M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2z"/><line x1="9" y1="14" x2="15" y2="14"/></svg>
      <div class="rail-dot" style="background:{status_dot(stfu[2])};color:{status_dot(stfu[2])}"></div>
    </div>

    <div class="rail-sep"></div>

    <div class="rail-item" data-label="Dashboard  &#8984;D" onclick="nav('dashboard')">
      <svg viewBox="0 0 24 24"><polygon points="12 2 2 7 12 12 22 7"/><polyline points="2 17 12 22 22 17"/><polyline points="2 12 12 17 22 12"/></svg>
    </div>

    <div class="rail-bottom">
      <div class="rail-sep"></div>
      <div class="rail-item" data-label="Settings" onclick="window.webkit.messageHandlers.lfg.postMessage({{action:'open-settings'}})">
        <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42"/></svg>
      </div>
    </div>
  </nav>

  <!-- MAIN CONTENT -->
  <main class="main">
    <div class="greeting">Welcome to <span>LFG</span></div>
    <div class="greeting-sub">Local File Guardian &middot; {timestamp}</div>

    <!-- GLASS DISK BAR -->
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

LFG.init({{ context: "Home", moduleVersion: "2.4.0" }});

function nav(mod) {{
  window.webkit.messageHandlers.lfg.postMessage({{ action: 'navigate', target: mod }});
}}

document.addEventListener('keydown', function(e) {{
  if (e.metaKey && e.key === '1') nav('wtfs');
  if (e.metaKey && e.key === '2') nav('dtf');
  if (e.metaKey && e.key === '3') nav('btau');
  if (e.metaKey && e.key === '4') nav('devdrive');
  if (e.metaKey && e.key === '5') nav('stfu');
  if (e.metaKey && e.key === 'd') nav('dashboard');
}});
  </script>
</body>
</html>'''

with open(html_file, 'w') as f:
    f.write(html)
PYEOF

"$VIEWER" "$HTML_FILE" "LFG - Local File Guardian" &
disown
echo "LFG launched (Liquid Glass theme)."

#!/usr/bin/env bash
# lfg splash - Icon rail + live dashboard home screen
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HTML_FILE="$LFG_DIR/.lfg_splash.html"
VIEWER="$LFG_DIR/viewer"

# Gather live disk stats
DISK_INFO=$(df -h / | awk 'NR==2{print $2 "|" $3 "|" $4 "|" $5}')
DISK_TOTAL=$(echo "$DISK_INFO" | cut -d'|' -f1)
DISK_USED_AMT=$(echo "$DISK_INFO" | cut -d'|' -f2)
DISK_FREE=$(echo "$DISK_INFO" | cut -d'|' -f3)
DISK_USED_PCT=$(echo "$DISK_INFO" | cut -d'|' -f4 | tr -d '%')
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")

# Read state.json for module status
STATE_FILE="$HOME/.config/lfg/state.json"
STATE_JSON="{}"
[[ -f "$STATE_FILE" ]] && STATE_JSON=$(cat "$STATE_FILE")

export LFG_DIR HTML_FILE DISK_TOTAL DISK_USED_AMT DISK_FREE DISK_USED_PCT TIMESTAMP STATE_JSON

python3 << 'PYEOF'
import json, os, sys

lfg_dir = os.environ.get("LFG_DIR", os.path.expanduser("~/tools/@yj/lfg"))
html_file = os.environ.get("HTML_FILE", lfg_dir + "/.lfg_splash.html")
disk_total = os.environ.get("DISK_TOTAL", "?")
disk_used_amt = os.environ.get("DISK_USED_AMT", "?")
disk_free = os.environ.get("DISK_FREE", "?")
disk_used_pct = int(os.environ.get("DISK_USED_PCT", "0"))
timestamp = os.environ.get("TIMESTAMP", "")

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

# Disk gauge parameters
gauge_pct = disk_used_pct
if gauge_pct > 90:
    gauge_color = "#ff4d6a"
    gauge_glow = "rgba(255,77,106,0.25)"
elif gauge_pct > 80:
    gauge_color = "#ffd166"
    gauge_glow = "rgba(255,209,102,0.2)"
elif gauge_pct > 70:
    gauge_color = "#8dcfff"
    gauge_glow = "rgba(141,207,255,0.2)"
else:
    gauge_color = "#4a9eff"
    gauge_glow = "rgba(74,158,255,0.15)"

# SVG arc calculation for disk gauge ring
import math
def arc_path(pct, r=54, cx=60, cy=60):
    angle = pct / 100 * 360
    rad = math.radians(angle - 90)
    end_x = cx + r * math.cos(rad)
    end_y = cy + r * math.sin(rad)
    large = 1 if angle > 180 else 0
    start_x = cx
    start_y = cy - r
    return f"M {start_x} {start_y} A {r} {r} 0 {large} 1 {end_x:.1f} {end_y:.1f}"

gauge_arc = arc_path(min(gauge_pct, 99.9))

# Status dot color
def status_dot(s):
    if s == "running": return "#ffd166"
    if s == "completed": return "#4a9eff"
    if s == "error": return "#ff4d6a"
    return "#3a3a44"

html = f'''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
{theme_css}

:root {{
  --rail-w: 56px;
  --rail-expanded: 180px;
  --accent: #4a9eff;
  --bg: #141418;
  --surface: #1c1c22;
  --border: #2a2a34;
  --text-dim: #6b6b78;
  --text-mid: #a0a0b0;
  --spring: cubic-bezier(0.22, 1, 0.36, 1);
}}

body {{
  padding: 0; margin: 0; overflow: hidden;
  display: flex; min-height: 100vh; user-select: none;
}}

/* === ICON RAIL === */
.rail {{
  width: var(--rail-w);
  min-height: 100vh;
  background: #111115;
  border-right: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 16px 0 12px;
  gap: 2px;
  z-index: 10;
  transition: width 0.3s var(--spring);
  overflow: hidden;
  flex-shrink: 0;
}}
.rail-logo {{
  font-size: 18px; font-weight: 800; color: #fff;
  letter-spacing: -1px; margin-bottom: 16px;
  white-space: nowrap;
}}
.rail-logo span {{ color: var(--accent); }}

.rail-item {{
  width: 40px; height: 40px;
  display: flex; align-items: center; justify-content: center;
  border-radius: 10px;
  cursor: pointer;
  transition: all 0.2s var(--spring);
  position: relative;
  flex-shrink: 0;
}}
.rail-item:hover {{
  background: rgba(255,255,255,0.06);
  transform: scale(1.08);
}}
.rail-item.active {{
  background: rgba(74,158,255,0.12);
}}
.rail-item svg {{
  width: 20px; height: 20px;
  stroke-width: 1.8;
  stroke: var(--text-dim);
  fill: none;
  stroke-linecap: round;
  stroke-linejoin: round;
  transition: stroke 0.15s;
}}
.rail-item:hover svg {{ stroke: #fff; }}
.rail-item[data-color="t1"]:hover svg {{ stroke: #4a9eff; }}
.rail-item[data-color="t2"]:hover svg {{ stroke: #6db8ff; }}
.rail-item[data-color="t3"]:hover svg {{ stroke: #2d6bc4; }}
.rail-item[data-color="t4"]:hover svg {{ stroke: #8dcfff; }}
.rail-item[data-color="t5"]:hover svg {{ stroke: #3d5afe; }}
.rail-item[data-color="t6"]:hover svg {{ stroke: #b4dfff; }}

/* Tooltip on hover */
.rail-item::after {{
  content: attr(data-label);
  position: absolute;
  left: 52px;
  background: #1e1e28;
  border: 1px solid var(--border);
  color: #fff;
  font-size: 11px;
  font-weight: 600;
  padding: 5px 10px;
  border-radius: 6px;
  white-space: nowrap;
  opacity: 0;
  pointer-events: none;
  transition: opacity 0.15s, transform 0.15s;
  transform: translateX(-4px);
  z-index: 20;
}}
.rail-item:hover::after {{
  opacity: 1;
  transform: translateX(0);
}}

.rail-sep {{
  width: 24px; height: 1px;
  background: var(--border);
  margin: 8px 0;
  flex-shrink: 0;
}}

.rail-bottom {{
  margin-top: auto;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 2px;
}}

/* Status dot on rail items */
.rail-dot {{
  position: absolute;
  top: 6px; right: 6px;
  width: 6px; height: 6px;
  border-radius: 50%;
  border: 1px solid #111115;
}}

/* Kbd hint */
.rail-kbd {{
  position: absolute;
  bottom: 2px; right: 4px;
  font-size: 7px;
  color: #3a3a44;
  font-weight: 600;
}}

/* === MAIN CONTENT === */
.main {{
  flex: 1;
  display: flex;
  flex-direction: column;
  padding: 28px 36px 24px;
  overflow-y: auto;
  animation: fadeIn 0.4s ease-out;
}}
@keyframes fadeIn {{
  from {{ opacity: 0; transform: translateY(8px); }}
  to {{ opacity: 1; transform: translateY(0); }}
}}

/* Hero section */
.hero {{
  display: flex;
  gap: 36px;
  align-items: flex-start;
  margin-bottom: 28px;
}}

/* Disk gauge */
.gauge-wrap {{
  flex-shrink: 0;
  position: relative;
  width: 120px;
  height: 120px;
}}
.gauge-wrap svg {{
  width: 120px;
  height: 120px;
}}
.gauge-bg {{
  fill: none;
  stroke: #1e1e28;
  stroke-width: 8;
}}
.gauge-fill {{
  fill: none;
  stroke: {gauge_color};
  stroke-width: 8;
  stroke-linecap: round;
  filter: drop-shadow(0 0 6px {gauge_glow});
  transition: stroke-dashoffset 1s var(--spring);
}}
.gauge-center {{
  position: absolute;
  top: 50%; left: 50%;
  transform: translate(-50%, -50%);
  text-align: center;
}}
.gauge-pct {{
  font-size: 28px;
  font-weight: 800;
  color: {gauge_color};
  letter-spacing: -1px;
  line-height: 1;
}}
.gauge-label {{
  font-size: 9px;
  color: var(--text-dim);
  text-transform: uppercase;
  letter-spacing: 1px;
  margin-top: 2px;
}}

/* Stats pills */
.stats-area {{
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 12px;
}}
.stats-row {{
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
}}
.stat-pill {{
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: 10px 14px;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  min-width: 120px;
  flex: 1;
  transition: border-color 0.15s, transform 0.15s;
  cursor: pointer;
}}
.stat-pill:hover {{
  border-color: var(--accent);
  transform: translateY(-1px);
}}
.stat-pill .sp-label {{
  font-size: 9px;
  text-transform: uppercase;
  letter-spacing: 0.8px;
  color: var(--text-dim);
}}
.stat-pill .sp-value {{
  font-size: 18px;
  font-weight: 700;
  color: #fff;
  line-height: 1.1;
}}
.stat-pill .sp-value.accent {{ color: var(--accent); }}
.stat-pill .sp-value.warn {{ color: #ffd166; }}
.stat-pill .sp-value.good {{ color: #4a9eff; }}
.stat-pill .sp-value.danger {{ color: #ff4d6a; }}

/* Greeting */
.greeting {{
  font-size: 22px;
  font-weight: 700;
  color: #fff;
  letter-spacing: -0.5px;
  margin-bottom: 4px;
}}
.greeting span {{ color: var(--accent); }}
.greeting-sub {{
  font-size: 12px;
  color: var(--text-dim);
  margin-bottom: 2px;
}}

/* === MODULE CARDS GRID === */
.section-header {{
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 1.2px;
  color: var(--text-dim);
  margin-bottom: 10px;
  padding-bottom: 6px;
  border-bottom: 1px solid var(--border);
}}

.mod-grid {{
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 10px;
  margin-bottom: 24px;
}}
.mod-card {{
  padding: 14px 16px;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  cursor: pointer;
  transition: all 0.25s var(--spring);
  position: relative;
  overflow: hidden;
}}
.mod-card::before {{
  content: '';
  position: absolute;
  top: 0; left: 0; right: 0;
  height: 2px;
  background: var(--card-accent);
  opacity: 0;
  transition: opacity 0.2s;
}}
.mod-card:hover {{
  border-color: var(--card-accent);
  transform: translateY(-2px);
  box-shadow: 0 8px 24px rgba(0,0,0,0.25);
}}
.mod-card:hover::before {{ opacity: 1; }}
.mod-card .mc-top {{
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 8px;
}}
.mod-card .mc-icon {{
  width: 32px; height: 32px;
  border-radius: 8px;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
}}
.mod-card .mc-icon svg {{
  width: 18px; height: 18px;
  stroke-width: 1.8;
  fill: none;
  stroke-linecap: round;
  stroke-linejoin: round;
}}
.mod-card .mc-name {{
  font-size: 13px;
  font-weight: 700;
  color: #fff;
}}
.mod-card .mc-full {{
  font-size: 9px;
  color: var(--text-dim);
  letter-spacing: 0.5px;
}}
.mod-card .mc-status {{
  font-size: 11px;
  color: var(--text-mid);
  line-height: 1.4;
}}
.mod-card .mc-status strong {{
  color: #fff;
  font-weight: 600;
}}
.mod-card .mc-kbd {{
  position: absolute;
  top: 10px; right: 12px;
  font-size: 9px;
  color: #3a3a44;
  padding: 1px 5px;
  border: 1px solid #2a2a34;
  border-radius: 3px;
}}
.mod-card .mc-dot {{
  width: 6px; height: 6px;
  border-radius: 50%;
  flex-shrink: 0;
}}

/* === RECENT ACTIVITY === */
.activity {{
  margin-bottom: 20px;
}}
.activity-item {{
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 0;
  border-bottom: 1px solid #1e1e26;
  font-size: 11px;
  color: var(--text-mid);
}}
.activity-item:last-child {{ border-bottom: none; }}
.activity-dot {{
  width: 6px; height: 6px;
  border-radius: 50%;
  flex-shrink: 0;
}}
.activity-time {{
  margin-left: auto;
  font-size: 10px;
  color: var(--text-dim);
  white-space: nowrap;
}}

/* === QUICK ACTIONS === */
.quick-bar {{
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}}
.qbtn {{
  padding: 7px 14px;
  font-size: 11px;
  font-weight: 600;
  font-family: inherit;
  color: var(--text-mid);
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 6px;
  cursor: pointer;
  transition: all 0.15s;
}}
.qbtn:hover {{
  border-color: var(--accent);
  color: var(--accent);
  background: rgba(74,158,255,0.06);
}}

/* === FOOTER === */
.splash-footer {{
  margin-top: auto;
  padding-top: 16px;
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
  <!-- ICON RAIL -->
  <nav class="rail">
    <div class="rail-logo"><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="28" height="28" aria-label="LFG">
  <path d="M 32 4 L 10 12 L 10 36 C 10 48 20 56 32 60 C 44 56 54 48 54 36 L 54 12 Z" stroke="#ffffff" stroke-width="2.5" stroke-linejoin="miter" stroke-linecap="square" fill="none"/>
  <circle cx="32" cy="33" r="14" stroke="#ffffff" stroke-width="2" fill="none"/>
  <circle cx="32" cy="33" r="8" stroke="#4a9eff" stroke-width="2" fill="none"/>
  <circle cx="32" cy="33" r="3" stroke="#ffffff" stroke-width="1.5" fill="#ffffff" fill-opacity="0.15"/>
  <line x1="34" y1="31" x2="43" y2="22" stroke="#4a9eff" stroke-width="2" stroke-linecap="round"/>
  <rect x="30.5" y="31.5" width="3" height="3" rx="0.5" fill="#4a9eff"/>
  <rect x="41.5" y="20.5" width="3" height="3" rx="0.5" fill="#ffffff"/>
  <line x1="10" y1="16" x2="14" y2="16" stroke="#ffffff" stroke-width="1.5" stroke-linecap="square"/>
  <line x1="54" y1="16" x2="50" y2="16" stroke="#ffffff" stroke-width="1.5" stroke-linecap="square"/>
</svg></div>

    <div class="rail-item" data-color="t1" data-label="WTFS" data-module="wtfs" onclick="nav('wtfs')">
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="20" height="20">
  <defs><clipPath id="wtfs-lens-clip"><circle cx="25" cy="25" r="17"/></clipPath></defs>
  <line x1="38" y1="38" x2="55" y2="55" stroke="#4a9eff" stroke-width="4" stroke-linecap="round"/>
  <circle cx="25" cy="25" r="19" stroke="#4a9eff" stroke-width="2" fill="#0d1117"/>
  <circle cx="25" cy="25" r="11" stroke="#4a9eff" stroke-width="1.5" stroke-dasharray="2 3" fill="none" opacity="0.45"/>
  <path d="M25,25 L41,25 A16,16 0 0,0 25,9 Z" fill="#4a9eff" opacity="0.85" clip-path="url(#wtfs-lens-clip)"/>
  <path d="M25,25 L25,41 A16,16 0 0,0 41,25 Z" fill="#4a9eff" opacity="0.50" clip-path="url(#wtfs-lens-clip)"/>
  <path d="M25,25 L9,25 A16,16 0 0,0 25,41 Z" fill="#4a9eff" opacity="0.25" clip-path="url(#wtfs-lens-clip)"/>
  <path d="M25,25 L25,9 A16,16 0 0,0 9,25 Z" fill="none" stroke="#4a9eff" stroke-width="1.5" stroke-dasharray="2 2" opacity="0.70" clip-path="url(#wtfs-lens-clip)"/>
  <line x1="25" y1="25" x2="25" y2="9" stroke="#4a9eff" stroke-width="1" opacity="0.6" clip-path="url(#wtfs-lens-clip)"/>
  <line x1="25" y1="25" x2="41" y2="25" stroke="#4a9eff" stroke-width="1" opacity="0.6" clip-path="url(#wtfs-lens-clip)"/>
  <line x1="25" y1="25" x2="25" y2="41" stroke="#4a9eff" stroke-width="1" opacity="0.6" clip-path="url(#wtfs-lens-clip)"/>
  <line x1="25" y1="25" x2="9" y2="25" stroke="#4a9eff" stroke-width="1" opacity="0.6" clip-path="url(#wtfs-lens-clip)"/>
  <circle cx="25" cy="25" r="2" fill="#4a9eff" opacity="0.9"/>
  <line x1="25" y1="25" x2="35" y2="15" stroke="#4a9eff" stroke-width="1.5" stroke-linecap="round" opacity="0.9" clip-path="url(#wtfs-lens-clip)"/>
  <circle cx="25" cy="25" r="19" stroke="#4a9eff" stroke-width="2" fill="none"/>
</svg>
      <div class="rail-dot" style="background:{status_dot(wtfs[2])}"></div>
      <div class="rail-kbd">1</div>
    </div>

    <div class="rail-item" data-color="t2" data-label="DTF" data-module="dtf" onclick="nav('dtf')">
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="20" height="20">
  <line x1="8" y1="8" x2="44" y2="44" stroke="#6db8ff" stroke-width="2.5" stroke-linecap="round"/>
  <rect x="40" y="42" width="14" height="5" rx="1" fill="#6db8ff" opacity="0.9" transform="rotate(45 44 44)"/>
  <line x1="44" y1="47" x2="38" y2="58" stroke="#6db8ff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="47" y1="47" x2="44" y2="59" stroke="#6db8ff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="50" y1="46" x2="50" y2="58" stroke="#6db8ff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="53" y1="44" x2="56" y2="56" stroke="#6db8ff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="55" y1="42" x2="61" y2="52" stroke="#6db8ff" stroke-width="1.5" stroke-linecap="round"/>
  <rect x="34" y="44" width="16" height="6" rx="1" stroke="#6db8ff" stroke-width="1.5" fill="#6db8ff" fill-opacity="0.2"/>
  <rect x="34" y="37" width="16" height="6" rx="1" stroke="#6db8ff" stroke-width="1.5" fill="#6db8ff" fill-opacity="0.2"/>
  <rect x="34" y="30" width="16" height="6" rx="1" stroke="#6db8ff" stroke-width="1.5" fill="#6db8ff" fill-opacity="0.2"/>
  <line x1="36" y1="33" x2="48" y2="33" stroke="#6db8ff" stroke-width="0.75" stroke-linecap="round" opacity="0.5"/>
  <line x1="36" y1="40" x2="48" y2="40" stroke="#6db8ff" stroke-width="0.75" stroke-linecap="round" opacity="0.5"/>
  <line x1="36" y1="47" x2="48" y2="47" stroke="#6db8ff" stroke-width="0.75" stroke-linecap="round" opacity="0.5"/>
  <rect x="6" y="28" width="8" height="4" rx="1" stroke="#6db8ff" stroke-width="1.5" fill="#6db8ff" fill-opacity="0.15" transform="rotate(-20 10 30)"/>
  <rect x="10" y="14" width="5" height="3" rx="0.5" stroke="#6db8ff" stroke-width="1.5" fill="#6db8ff" fill-opacity="0.1" transform="rotate(-35 12 15)"/>
  <rect x="4" y="18" width="3" height="3" rx="0.5" fill="#6db8ff" opacity="0.4"/>
  <circle cx="20" cy="20" r="1.5" fill="#6db8ff" opacity="0.3"/>
  <circle cx="28" cy="28" r="1.5" fill="#6db8ff" opacity="0.3"/>
  <circle cx="36" cy="36" r="1.5" fill="#6db8ff" opacity="0.3"/>
</svg>
      <div class="rail-dot" style="background:{status_dot(dtf[2])}"></div>
      <div class="rail-kbd">2</div>
    </div>

    <div class="rail-item" data-color="t3" data-label="BTAU" data-module="btau" onclick="nav('btau')">
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="20" height="20">
  <circle cx="32" cy="32" r="26" stroke="#2d6bc4" stroke-width="2"/>
  <circle cx="32" cy="32" r="19" stroke="#2d6bc4" stroke-width="1.5"/>
  <line x1="32" y1="13" x2="32" y2="7" stroke="#2d6bc4" stroke-width="2" stroke-linecap="round"/>
  <line x1="32" y1="51" x2="32" y2="57" stroke="#2d6bc4" stroke-width="2" stroke-linecap="round"/>
  <line x1="13" y1="32" x2="7" y2="32" stroke="#2d6bc4" stroke-width="2" stroke-linecap="round"/>
  <line x1="51" y1="32" x2="57" y2="32" stroke="#2d6bc4" stroke-width="2" stroke-linecap="round"/>
  <circle cx="32" cy="32" r="7" stroke="#2d6bc4" stroke-width="1.5"/>
  <g stroke="#2d6bc4" stroke-width="1.5" stroke-linecap="round">
    <line x1="32" y1="25" x2="32" y2="22"/>
    <line x1="38.06" y1="28.5" x2="40.6" y2="27"/>
    <line x1="38.06" y1="35.5" x2="40.6" y2="37"/>
    <line x1="32" y1="39" x2="32" y2="42"/>
    <line x1="25.94" y1="35.5" x2="23.4" y2="37"/>
    <line x1="25.94" y1="28.5" x2="23.4" y2="27"/>
  </g>
  <circle cx="32" cy="32" r="2" fill="#2d6bc4"/>
  <path d="M 10 52 C 4 40 4 20 17 13" stroke="#2d6bc4" stroke-width="1.75" stroke-linecap="round" fill="none"/>
  <polyline points="12,11 17,13 15,19" stroke="#2d6bc4" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
</svg>
      <div class="rail-dot" style="background:{status_dot(btau[2])}"></div>
      <div class="rail-kbd">3</div>
    </div>

    <div class="rail-item" data-color="t4" data-label="DEVDRIVE" data-module="devdrive" onclick="nav('devdrive')">
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="20" height="20">
  <ellipse cx="32" cy="46" rx="18" ry="5" stroke="#8dcfff" stroke-width="1.75"/>
  <line x1="14" y1="46" x2="14" y2="52" stroke="#8dcfff" stroke-width="1.75" stroke-linecap="round"/>
  <line x1="50" y1="46" x2="50" y2="52" stroke="#8dcfff" stroke-width="1.75" stroke-linecap="round"/>
  <path d="M 14 52 Q 32 58 50 52" stroke="#8dcfff" stroke-width="1.75" stroke-linecap="round" fill="none"/>
  <circle cx="44" cy="47" r="1.5" fill="#8dcfff" opacity="0.8"/>
  <line x1="20" y1="47" x2="38" y2="47" stroke="#8dcfff" stroke-width="1" stroke-linecap="round" opacity="0.4"/>
  <line x1="32" y1="41" x2="32" y2="30" stroke="#8dcfff" stroke-width="1.75" stroke-linecap="round"/>
  <line x1="32" y1="30" x2="20" y2="30" stroke="#8dcfff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="20" y1="30" x2="20" y2="22" stroke="#8dcfff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="32" y1="30" x2="44" y2="30" stroke="#8dcfff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="44" y1="30" x2="44" y2="22" stroke="#8dcfff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="20" y1="22" x2="13" y2="22" stroke="#8dcfff" stroke-width="1.25" stroke-linecap="round"/>
  <line x1="13" y1="22" x2="13" y2="16" stroke="#8dcfff" stroke-width="1.25" stroke-linecap="round"/>
  <line x1="20" y1="22" x2="27" y2="22" stroke="#8dcfff" stroke-width="1.25" stroke-linecap="round"/>
  <line x1="27" y1="22" x2="27" y2="16" stroke="#8dcfff" stroke-width="1.25" stroke-linecap="round"/>
  <line x1="44" y1="22" x2="44" y2="14" stroke="#8dcfff" stroke-width="1.25" stroke-linecap="round"/>
  <rect x="10" y="12" width="6" height="4" rx="1" stroke="#8dcfff" stroke-width="1.25"/>
  <rect x="24" y="12" width="6" height="4" rx="1" stroke="#8dcfff" stroke-width="1.25"/>
  <rect x="41" y="10" width="6" height="4" rx="1" stroke="#8dcfff" stroke-width="1.25"/>
  <line x1="12" y1="14" x2="14.5" y2="14" stroke="#8dcfff" stroke-width="1" stroke-linecap="round"/>
  <polyline points="13.5,12.8 14.8,14 13.5,15.2" stroke="#8dcfff" stroke-width="1" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
  <line x1="26" y1="14" x2="28.5" y2="14" stroke="#8dcfff" stroke-width="1" stroke-linecap="round"/>
  <polyline points="27.5,12.8 28.8,14 27.5,15.2" stroke="#8dcfff" stroke-width="1" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
  <line x1="43" y1="12" x2="45.5" y2="12" stroke="#8dcfff" stroke-width="1" stroke-linecap="round"/>
  <polyline points="44.5,10.8 45.8,12 44.5,13.2" stroke="#8dcfff" stroke-width="1" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
</svg>
      <div class="rail-dot" style="background:{status_dot(dd[2])}"></div>
      <div class="rail-kbd">4</div>
    </div>

    <div class="rail-item" data-color="t5" data-label="STFU" data-module="stfu" onclick="nav('stfu')">
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="20" height="20">
  <path d="M14 8 L8 8 L8 20" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M8 44 L8 56 L14 56" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M50 8 L56 8 L56 20" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M56 44 L56 56 L50 56" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M8 28 C8 28 16 28 20 32 C24 36 28 36 32 32" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" fill="none" opacity="0.7"/>
  <path d="M56 36 C56 36 48 36 44 32 C40 28 36 28 32 32" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" fill="none" opacity="0.7"/>
  <path d="M8 36 C8 36 16 36 20 32 C24 28 28 28 32 32" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" fill="none" opacity="0.45"/>
  <path d="M56 28 C56 28 48 28 44 32 C40 36 36 36 32 32" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" fill="none" opacity="0.45"/>
  <line x1="8" y1="20" x2="8" y2="44" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" opacity="0.5"/>
  <line x1="56" y1="20" x2="56" y2="44" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" opacity="0.5"/>
  <line x1="8" y1="26" x2="14" y2="26" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" opacity="0.6"/>
  <line x1="8" y1="38" x2="14" y2="38" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" opacity="0.6"/>
  <line x1="56" y1="26" x2="50" y2="26" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" opacity="0.6"/>
  <line x1="56" y1="38" x2="50" y2="38" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" opacity="0.6"/>
  <circle cx="32" cy="32" r="5.5" stroke="#3d5afe" stroke-width="1.5" fill="none"/>
  <circle cx="32" cy="32" r="2.5" fill="#3d5afe"/>
  <path d="M38 26 A8 8 0 0 1 46 34" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" fill="none" opacity="0.4"/>
  <line x1="44" y1="36" x2="49" y2="41" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" opacity="0.4"/>
</svg>
      <div class="rail-dot" style="background:{status_dot(stfu[2])}"></div>
      <div class="rail-kbd">5</div>
    </div>

    <div class="rail-sep"></div>

    <div class="rail-item" data-color="t6" data-label="AI Engine" data-module="ai" onclick="nav('dashboard')">
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="20" height="20">
  <circle cx="32" cy="32" r="27" stroke="#b4dfff" stroke-width="0.75" stroke-dasharray="3 4" fill="none" opacity="0.25"/>
  <line x1="32" y1="32" x2="32" y2="10" stroke="#b4dfff" stroke-width="1.5" stroke-linecap="round" opacity="0.8"/>
  <line x1="32" y1="32" x2="51" y2="21" stroke="#b4dfff" stroke-width="1.5" stroke-linecap="round" opacity="0.8"/>
  <line x1="32" y1="32" x2="51" y2="43" stroke="#b4dfff" stroke-width="1.5" stroke-linecap="round" opacity="0.8"/>
  <line x1="32" y1="32" x2="32" y2="54" stroke="#b4dfff" stroke-width="1.5" stroke-linecap="round" opacity="0.8"/>
  <line x1="32" y1="32" x2="13" y2="43" stroke="#b4dfff" stroke-width="1.5" stroke-linecap="round" opacity="0.8"/>
  <line x1="32" y1="32" x2="13" y2="21" stroke="#b4dfff" stroke-width="1.5" stroke-linecap="round" opacity="0.8"/>
  <line x1="32" y1="10" x2="51" y2="21" stroke="#b4dfff" stroke-width="1" stroke-linecap="round" opacity="0.4"/>
  <line x1="51" y1="21" x2="51" y2="43" stroke="#b4dfff" stroke-width="1" stroke-linecap="round" opacity="0.4"/>
  <line x1="51" y1="43" x2="32" y2="54" stroke="#b4dfff" stroke-width="1" stroke-linecap="round" opacity="0.4"/>
  <line x1="32" y1="54" x2="13" y2="43" stroke="#b4dfff" stroke-width="1" stroke-linecap="round" opacity="0.4"/>
  <line x1="13" y1="43" x2="13" y2="21" stroke="#b4dfff" stroke-width="1" stroke-linecap="round" opacity="0.4"/>
  <line x1="13" y1="21" x2="32" y2="10" stroke="#b4dfff" stroke-width="1" stroke-linecap="round" opacity="0.4"/>
  <line x1="32" y1="10" x2="51" y2="43" stroke="#b4dfff" stroke-width="0.75" stroke-linecap="round" opacity="0.25"/>
  <line x1="51" y1="21" x2="13" y2="43" stroke="#b4dfff" stroke-width="0.75" stroke-linecap="round" opacity="0.25"/>
  <line x1="51" y1="21" x2="32" y2="54" stroke="#b4dfff" stroke-width="0.75" stroke-linecap="round" opacity="0.2"/>
  <line x1="13" y1="21" x2="51" y2="43" stroke="#b4dfff" stroke-width="0.75" stroke-linecap="round" opacity="0.2"/>
  <circle cx="32" cy="10" r="3" stroke="#b4dfff" stroke-width="1.5" fill="none"/>
  <circle cx="32" cy="10" r="1.25" fill="#b4dfff"/>
  <circle cx="51" cy="21" r="3" stroke="#b4dfff" stroke-width="1.5" fill="none"/>
  <circle cx="51" cy="21" r="1.25" fill="#b4dfff"/>
  <circle cx="51" cy="43" r="3" stroke="#b4dfff" stroke-width="1.5" fill="none"/>
  <circle cx="51" cy="43" r="1.25" fill="#b4dfff"/>
  <circle cx="32" cy="54" r="3" stroke="#b4dfff" stroke-width="1.5" fill="none"/>
  <circle cx="32" cy="54" r="1.25" fill="#b4dfff"/>
  <circle cx="13" cy="43" r="3" stroke="#b4dfff" stroke-width="1.5" fill="none"/>
  <circle cx="13" cy="43" r="1.25" fill="#b4dfff"/>
  <circle cx="13" cy="21" r="3" stroke="#b4dfff" stroke-width="1.5" fill="none"/>
  <circle cx="13" cy="21" r="1.25" fill="#b4dfff"/>
  <circle cx="32" cy="32" r="7" stroke="#b4dfff" stroke-width="1.5" fill="none"/>
  <path d="M32 27 L36.3 34.5 L27.7 34.5 Z" stroke="#b4dfff" stroke-width="1.25" stroke-linejoin="round" fill="none"/>
  <circle cx="32" cy="32" r="1.75" fill="#b4dfff"/>
</svg>
    </div>

    <div class="rail-bottom">
      <div class="rail-sep"></div>
      <div class="rail-item" data-color="t1" data-label="Dashboard" onclick="nav('dashboard')">
        <svg viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/></svg>
      </div>
      <div class="rail-item" data-label="Settings" onclick="window.webkit.messageHandlers.lfg.postMessage({{action:'open-settings'}})">
        <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42"/></svg>
      </div>
    </div>
  </nav>

  <!-- MAIN CONTENT -->
  <main class="main">
    <div class="greeting">Welcome to <span>LFG</span></div>
    <div class="greeting-sub">Local File Guardian &middot; {timestamp}</div>

    <!-- HERO: Gauge + Stats -->
    <div class="hero">
      <div class="gauge-wrap">
        <svg viewBox="0 0 120 120">
          <circle class="gauge-bg" cx="60" cy="60" r="54"/>
          <path class="gauge-fill" d="{gauge_arc}"/>
        </svg>
        <div class="gauge-center">
          <div class="gauge-pct">{gauge_pct}%</div>
          <div class="gauge-label">Used</div>
        </div>
      </div>
      <div class="stats-area">
        <div class="stats-row">
          <div class="stat-pill" onclick="nav('wtfs')">
            <div class="sp-label">Disk Free</div>
            <div class="sp-value {'danger' if gauge_pct > 90 else 'warn' if gauge_pct > 80 else 'good'}">{disk_free}</div>
          </div>
          <div class="stat-pill" onclick="nav('wtfs')">
            <div class="sp-label">Total / Used</div>
            <div class="sp-value">{disk_total} / {disk_used_amt}</div>
          </div>
          <div class="stat-pill" onclick="nav('dtf')">
            <div class="sp-label">Reclaimable</div>
            <div class="sp-value accent">{dtf[0]}</div>
          </div>
        </div>
        <div class="stats-row">
          <div class="stat-pill" onclick="nav('wtfs')">
            <div class="sp-label">Projects Scanned</div>
            <div class="sp-value">{wtfs[1]}</div>
          </div>
          <div class="stat-pill" onclick="nav('btau')">
            <div class="sp-label">Backups</div>
            <div class="sp-value">{btau[0]}</div>
          </div>
          <div class="stat-pill" onclick="nav('stfu')">
            <div class="sp-label">STFU Analysis</div>
            <div class="sp-value accent">{stfu[0]}</div>
          </div>
        </div>
      </div>
    </div>

    <!-- MODULE CARDS -->
    <div class="section-header">Modules</div>
    <div class="mod-grid">
      <div class="mod-card" style="--card-accent:#4a9eff" onclick="nav('wtfs')">
        <div class="mc-kbd">\u23181</div>
        <div class="mc-top">
          <div class="mc-icon" style="background:rgba(74,158,255,0.1)">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="18" height="18" style="stroke:#4a9eff">
  <defs><clipPath id="wtfs-card-clip"><circle cx="25" cy="25" r="17"/></clipPath></defs>
  <line x1="38" y1="38" x2="55" y2="55" stroke="#4a9eff" stroke-width="4" stroke-linecap="round"/>
  <circle cx="25" cy="25" r="19" stroke="#4a9eff" stroke-width="2" fill="#0d1117"/>
  <circle cx="25" cy="25" r="11" stroke="#4a9eff" stroke-width="1.5" stroke-dasharray="2 3" fill="none" opacity="0.45"/>
  <path d="M25,25 L41,25 A16,16 0 0,0 25,9 Z" fill="#4a9eff" opacity="0.85" clip-path="url(#wtfs-card-clip)"/>
  <path d="M25,25 L25,41 A16,16 0 0,0 41,25 Z" fill="#4a9eff" opacity="0.50" clip-path="url(#wtfs-card-clip)"/>
  <path d="M25,25 L9,25 A16,16 0 0,0 25,41 Z" fill="#4a9eff" opacity="0.25" clip-path="url(#wtfs-card-clip)"/>
  <path d="M25,25 L25,9 A16,16 0 0,0 9,25 Z" fill="none" stroke="#4a9eff" stroke-width="1.5" stroke-dasharray="2 2" opacity="0.70" clip-path="url(#wtfs-card-clip)"/>
  <circle cx="25" cy="25" r="2" fill="#4a9eff" opacity="0.9"/>
  <line x1="25" y1="25" x2="35" y2="15" stroke="#4a9eff" stroke-width="1.5" stroke-linecap="round" opacity="0.9" clip-path="url(#wtfs-card-clip)"/>
  <circle cx="25" cy="25" r="19" stroke="#4a9eff" stroke-width="2" fill="none"/>
</svg>
          </div>
          <div>
            <div class="mc-name">WTFS</div>
            <div class="mc-full">Where's The Free Space</div>
          </div>
          <div class="mc-dot" style="background:{status_dot(wtfs[2])};margin-left:auto"></div>
        </div>
        <div class="mc-status">Last: <strong>{wtfs[0]}</strong> across <strong>{wtfs[1]}</strong> dirs</div>
      </div>

      <div class="mod-card" style="--card-accent:#6db8ff" onclick="nav('dtf')">
        <div class="mc-kbd">\u23182</div>
        <div class="mc-top">
          <div class="mc-icon" style="background:rgba(109,184,255,0.1)">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="18" height="18" style="stroke:#6db8ff">
  <line x1="8" y1="8" x2="44" y2="44" stroke="#6db8ff" stroke-width="2.5" stroke-linecap="round"/>
  <rect x="40" y="42" width="14" height="5" rx="1" fill="#6db8ff" opacity="0.9" transform="rotate(45 44 44)"/>
  <line x1="44" y1="47" x2="38" y2="58" stroke="#6db8ff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="47" y1="47" x2="44" y2="59" stroke="#6db8ff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="50" y1="46" x2="50" y2="58" stroke="#6db8ff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="53" y1="44" x2="56" y2="56" stroke="#6db8ff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="55" y1="42" x2="61" y2="52" stroke="#6db8ff" stroke-width="1.5" stroke-linecap="round"/>
  <rect x="34" y="44" width="16" height="6" rx="1" stroke="#6db8ff" stroke-width="1.5" fill="#6db8ff" fill-opacity="0.2"/>
  <rect x="34" y="37" width="16" height="6" rx="1" stroke="#6db8ff" stroke-width="1.5" fill="#6db8ff" fill-opacity="0.2"/>
  <rect x="34" y="30" width="16" height="6" rx="1" stroke="#6db8ff" stroke-width="1.5" fill="#6db8ff" fill-opacity="0.2"/>
  <line x1="36" y1="33" x2="48" y2="33" stroke="#6db8ff" stroke-width="0.75" stroke-linecap="round" opacity="0.5"/>
  <line x1="36" y1="40" x2="48" y2="40" stroke="#6db8ff" stroke-width="0.75" stroke-linecap="round" opacity="0.5"/>
  <line x1="36" y1="47" x2="48" y2="47" stroke="#6db8ff" stroke-width="0.75" stroke-linecap="round" opacity="0.5"/>
  <rect x="6" y="28" width="8" height="4" rx="1" stroke="#6db8ff" stroke-width="1.5" fill="#6db8ff" fill-opacity="0.15" transform="rotate(-20 10 30)"/>
  <rect x="10" y="14" width="5" height="3" rx="0.5" stroke="#6db8ff" stroke-width="1.5" fill="#6db8ff" fill-opacity="0.1" transform="rotate(-35 12 15)"/>
  <rect x="4" y="18" width="3" height="3" rx="0.5" fill="#6db8ff" opacity="0.4"/>
  <circle cx="20" cy="20" r="1.5" fill="#6db8ff" opacity="0.3"/>
  <circle cx="28" cy="28" r="1.5" fill="#6db8ff" opacity="0.3"/>
  <circle cx="36" cy="36" r="1.5" fill="#6db8ff" opacity="0.3"/>
</svg>
          </div>
          <div>
            <div class="mc-name">DTF</div>
            <div class="mc-full">Delete Temp Files</div>
          </div>
          <div class="mc-dot" style="background:{status_dot(dtf[2])};margin-left:auto"></div>
        </div>
        <div class="mc-status"><strong>{dtf[0]}</strong> reclaimable ({dtf[1]} mode)</div>
      </div>

      <div class="mod-card" style="--card-accent:#2d6bc4" onclick="nav('btau')">
        <div class="mc-kbd">\u23183</div>
        <div class="mc-top">
          <div class="mc-icon" style="background:rgba(45,107,196,0.1)">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="18" height="18" style="stroke:#2d6bc4">
  <circle cx="32" cy="32" r="26" stroke="#2d6bc4" stroke-width="2"/>
  <circle cx="32" cy="32" r="19" stroke="#2d6bc4" stroke-width="1.5"/>
  <line x1="32" y1="13" x2="32" y2="7" stroke="#2d6bc4" stroke-width="2" stroke-linecap="round"/>
  <line x1="32" y1="51" x2="32" y2="57" stroke="#2d6bc4" stroke-width="2" stroke-linecap="round"/>
  <line x1="13" y1="32" x2="7" y2="32" stroke="#2d6bc4" stroke-width="2" stroke-linecap="round"/>
  <line x1="51" y1="32" x2="57" y2="32" stroke="#2d6bc4" stroke-width="2" stroke-linecap="round"/>
  <circle cx="32" cy="32" r="7" stroke="#2d6bc4" stroke-width="1.5"/>
  <g stroke="#2d6bc4" stroke-width="1.5" stroke-linecap="round">
    <line x1="32" y1="25" x2="32" y2="22"/>
    <line x1="38.06" y1="28.5" x2="40.6" y2="27"/>
    <line x1="38.06" y1="35.5" x2="40.6" y2="37"/>
    <line x1="32" y1="39" x2="32" y2="42"/>
    <line x1="25.94" y1="35.5" x2="23.4" y2="37"/>
    <line x1="25.94" y1="28.5" x2="23.4" y2="27"/>
  </g>
  <circle cx="32" cy="32" r="2" fill="#2d6bc4"/>
  <path d="M 10 52 C 4 40 4 20 17 13" stroke="#2d6bc4" stroke-width="1.75" stroke-linecap="round" fill="none"/>
  <polyline points="12,11 17,13 15,19" stroke="#2d6bc4" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
</svg>
          </div>
          <div>
            <div class="mc-name">BTAU</div>
            <div class="mc-full">Back That App Up</div>
          </div>
          <div class="mc-dot" style="background:{status_dot(btau[2])};margin-left:auto"></div>
        </div>
        <div class="mc-status"><strong>{btau[0]}</strong> backups, <strong>{btau[1]}</strong> total</div>
      </div>

      <div class="mod-card" style="--card-accent:#8dcfff" onclick="nav('devdrive')">
        <div class="mc-kbd">\u23184</div>
        <div class="mc-top">
          <div class="mc-icon" style="background:rgba(141,207,255,0.1)">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="18" height="18" style="stroke:#8dcfff">
  <ellipse cx="32" cy="46" rx="18" ry="5" stroke="#8dcfff" stroke-width="1.75"/>
  <line x1="14" y1="46" x2="14" y2="52" stroke="#8dcfff" stroke-width="1.75" stroke-linecap="round"/>
  <line x1="50" y1="46" x2="50" y2="52" stroke="#8dcfff" stroke-width="1.75" stroke-linecap="round"/>
  <path d="M 14 52 Q 32 58 50 52" stroke="#8dcfff" stroke-width="1.75" stroke-linecap="round" fill="none"/>
  <circle cx="44" cy="47" r="1.5" fill="#8dcfff" opacity="0.8"/>
  <line x1="20" y1="47" x2="38" y2="47" stroke="#8dcfff" stroke-width="1" stroke-linecap="round" opacity="0.4"/>
  <line x1="32" y1="41" x2="32" y2="30" stroke="#8dcfff" stroke-width="1.75" stroke-linecap="round"/>
  <line x1="32" y1="30" x2="20" y2="30" stroke="#8dcfff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="20" y1="30" x2="20" y2="22" stroke="#8dcfff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="32" y1="30" x2="44" y2="30" stroke="#8dcfff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="44" y1="30" x2="44" y2="22" stroke="#8dcfff" stroke-width="1.5" stroke-linecap="round"/>
  <line x1="20" y1="22" x2="13" y2="22" stroke="#8dcfff" stroke-width="1.25" stroke-linecap="round"/>
  <line x1="13" y1="22" x2="13" y2="16" stroke="#8dcfff" stroke-width="1.25" stroke-linecap="round"/>
  <line x1="20" y1="22" x2="27" y2="22" stroke="#8dcfff" stroke-width="1.25" stroke-linecap="round"/>
  <line x1="27" y1="22" x2="27" y2="16" stroke="#8dcfff" stroke-width="1.25" stroke-linecap="round"/>
  <line x1="44" y1="22" x2="44" y2="14" stroke="#8dcfff" stroke-width="1.25" stroke-linecap="round"/>
  <rect x="10" y="12" width="6" height="4" rx="1" stroke="#8dcfff" stroke-width="1.25"/>
  <rect x="24" y="12" width="6" height="4" rx="1" stroke="#8dcfff" stroke-width="1.25"/>
  <rect x="41" y="10" width="6" height="4" rx="1" stroke="#8dcfff" stroke-width="1.25"/>
  <line x1="12" y1="14" x2="14.5" y2="14" stroke="#8dcfff" stroke-width="1" stroke-linecap="round"/>
  <polyline points="13.5,12.8 14.8,14 13.5,15.2" stroke="#8dcfff" stroke-width="1" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
  <line x1="26" y1="14" x2="28.5" y2="14" stroke="#8dcfff" stroke-width="1" stroke-linecap="round"/>
  <polyline points="27.5,12.8 28.8,14 27.5,15.2" stroke="#8dcfff" stroke-width="1" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
  <line x1="43" y1="12" x2="45.5" y2="12" stroke="#8dcfff" stroke-width="1" stroke-linecap="round"/>
  <polyline points="44.5,10.8 45.8,12 44.5,13.2" stroke="#8dcfff" stroke-width="1" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
</svg>
          </div>
          <div>
            <div class="mc-name">DEVDRIVE</div>
            <div class="mc-full">Developer Drive</div>
          </div>
          <div class="mc-dot" style="background:{status_dot(dd[2])};margin-left:auto"></div>
        </div>
        <div class="mc-status"><strong>{dd[0]}</strong> projects, <strong>{dd[1]}</strong> volumes</div>
      </div>

      <div class="mod-card" style="--card-accent:#3d5afe" onclick="nav('stfu')">
        <div class="mc-kbd">\u23185</div>
        <div class="mc-top">
          <div class="mc-icon" style="background:rgba(61,90,254,0.1)">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="18" height="18" style="stroke:#3d5afe">
  <path d="M14 8 L8 8 L8 20" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M8 44 L8 56 L14 56" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M50 8 L56 8 L56 20" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M56 44 L56 56 L50 56" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M8 28 C8 28 16 28 20 32 C24 36 28 36 32 32" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" fill="none" opacity="0.7"/>
  <path d="M56 36 C56 36 48 36 44 32 C40 28 36 28 32 32" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" fill="none" opacity="0.7"/>
  <path d="M8 36 C8 36 16 36 20 32 C24 28 28 28 32 32" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" fill="none" opacity="0.45"/>
  <path d="M56 28 C56 28 48 28 44 32 C40 36 36 36 32 32" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" fill="none" opacity="0.45"/>
  <line x1="8" y1="20" x2="8" y2="44" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" opacity="0.5"/>
  <line x1="56" y1="20" x2="56" y2="44" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" opacity="0.5"/>
  <line x1="8" y1="26" x2="14" y2="26" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" opacity="0.6"/>
  <line x1="8" y1="38" x2="14" y2="38" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" opacity="0.6"/>
  <line x1="56" y1="26" x2="50" y2="26" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" opacity="0.6"/>
  <line x1="56" y1="38" x2="50" y2="38" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" opacity="0.6"/>
  <circle cx="32" cy="32" r="5.5" stroke="#3d5afe" stroke-width="1.5" fill="none"/>
  <circle cx="32" cy="32" r="2.5" fill="#3d5afe"/>
  <path d="M38 26 A8 8 0 0 1 46 34" stroke="#3d5afe" stroke-width="1.5" stroke-linecap="round" fill="none" opacity="0.4"/>
  <line x1="44" y1="36" x2="49" y2="41" stroke="#3d5afe" stroke-width="2" stroke-linecap="round" opacity="0.4"/>
</svg>
          </div>
          <div>
            <div class="mc-name">STFU</div>
            <div class="mc-full">Source Tree Forensics</div>
          </div>
          <div class="mc-dot" style="background:{status_dot(stfu[2])};margin-left:auto"></div>
        </div>
        <div class="mc-status">{stfu[0]}</div>
      </div>

      <div class="mod-card" style="--card-accent:#4a9eff" onclick="nav('dashboard')">
        <div class="mc-kbd">\u2318D</div>
        <div class="mc-top">
          <div class="mc-icon" style="background:rgba(74,158,255,0.1)">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none" width="18" height="18" style="stroke:#4a9eff">
  <path d="M 32 4 L 10 12 L 10 36 C 10 48 20 56 32 60 C 44 56 54 48 54 36 L 54 12 Z" stroke="#ffffff" stroke-width="2.5" stroke-linejoin="miter" stroke-linecap="square" fill="none"/>
  <circle cx="32" cy="33" r="14" stroke="#ffffff" stroke-width="2" fill="none"/>
  <circle cx="32" cy="33" r="8" stroke="#4a9eff" stroke-width="2" fill="none"/>
  <circle cx="32" cy="33" r="3" stroke="#ffffff" stroke-width="1.5" fill="#ffffff" fill-opacity="0.15"/>
  <line x1="34" y1="31" x2="43" y2="22" stroke="#4a9eff" stroke-width="2" stroke-linecap="round"/>
  <rect x="30.5" y="31.5" width="3" height="3" rx="0.5" fill="#4a9eff"/>
  <rect x="41.5" y="20.5" width="3" height="3" rx="0.5" fill="#ffffff"/>
  <line x1="10" y1="16" x2="14" y2="16" stroke="#ffffff" stroke-width="1.5" stroke-linecap="square"/>
  <line x1="54" y1="16" x2="50" y2="16" stroke="#ffffff" stroke-width="1.5" stroke-linecap="square"/>
</svg>
          </div>
          <div>
            <div class="mc-name">Dashboard</div>
            <div class="mc-full">Combined Module View</div>
          </div>
        </div>
        <div class="mc-status">All modules in one view</div>
      </div>
    </div>

    <!-- QUICK ACTIONS -->
    <div class="section-header">Quick Actions</div>
    <div class="quick-bar">
      <button class="qbtn" onclick="nav('wtfs')">Scan Disk</button>
      <button class="qbtn" onclick="nav('dtf')">Clean Caches</button>
      <button class="qbtn" onclick="nav('stfu')">Find Duplicates</button>
      <button class="qbtn" onclick="window.open('http://localhost:3031')">APM Monitor</button>
    </div>

    <!-- FOOTER -->
    <div class="splash-footer">
      <span>lfg v2.1.0 &middot; @yj tools</span>
      <span><a href="http://localhost:3031" target="_blank">APM</a></span>
    </div>
  </main>

  <script>
{ui_js}

LFG.init({{ context: "Home", moduleVersion: "2.1.0" }});

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

# Launch viewer (navigation happens in-process)
"$VIEWER" "$HTML_FILE" "LFG - Local File Guardian" &
disown
echo "LFG launched."

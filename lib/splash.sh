#!/usr/bin/env bash
# lfg splash - Animated splash screen with clickable module cards
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HTML_FILE="$LFG_DIR/.lfg_splash.html"
VIEWER="$LFG_DIR/viewer"
SELECT_FILE=$(mktemp /tmp/lfg_select.XXXXXX)

DISK_FREE=$(df -h / | awk 'NR==2{print $4}')
DISK_USED=$(df -h / | awk 'NR==2{print $5}')
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
THEME_CSS=$(cat "$LFG_DIR/lib/theme.css")
UI_JS=$(cat "$LFG_DIR/lib/ui.js")

python3 -c "
import sys, os

theme_css = open('$LFG_DIR/lib/theme.css').read()
ui_js = open('$LFG_DIR/lib/ui.js').read()

html = '''<!DOCTYPE html>
<html>
<head>
<meta charset=\"utf-8\">
<style>
''' + theme_css + '''
body {
  display: flex; flex-direction: column; align-items: center;
  justify-content: center; min-height: 100vh; padding: 52px 0 48px 0;
  overflow: hidden; user-select: none;
}
.splash { text-align: center; animation: lfgFadeIn 0.4s ease-out; }
@keyframes lfgFadeIn {
  from { opacity: 0; transform: translateY(12px) scale(0.98); }
  to { opacity: 1; transform: translateY(0) scale(1); }
}
.logo { font-size: 64px; font-weight: 800; letter-spacing: -2px; color: #fff; margin-bottom: 4px; }
.logo span { color: #4a9eff; }
.tagline { font-size: 13px; color: #6b6b78; letter-spacing: 2px; text-transform: uppercase; margin-bottom: 36px; }
.modules { display: flex; gap: 16px; margin-bottom: 36px; }
.module {
  width: 180px; padding: 20px 16px; background: #1c1c22; border: 1px solid #2a2a34;
  border-radius: 10px; text-align: center; transition: all 0.25s ease; cursor: pointer;
  animation: slideUp 0.5s ease-out both;
}
.module:nth-child(1) { animation-delay: 0.15s; }
.module:nth-child(2) { animation-delay: 0.30s; }
.module:nth-child(3) { animation-delay: 0.45s; }
.module:nth-child(4) { animation-delay: 0.60s; }
@keyframes slideUp { from { opacity: 0; transform: translateY(20px); } to { opacity: 1; transform: translateY(0); } }
.module:hover { border-color: #4a9eff; background: #1e1e28; transform: translateY(-4px); box-shadow: 0 8px 24px rgba(0,0,0,0.3); }
.module:active { transform: translateY(-1px); }
.module.selected { pointer-events: none; }
.module .icon { font-size: 28px; margin-bottom: 8px; }
.module .name { font-size: 16px; font-weight: 700; color: #fff; margin-bottom: 2px; }
.module .abbr { font-size: 10px; font-weight: 600; letter-spacing: 1.5px; text-transform: uppercase; margin-bottom: 6px; }
.module .desc { font-size: 11px; color: #6b6b78; line-height: 1.4; }
.module .kbd-hint { font-size: 9px; color: #3a3a44; margin-top: 8px; padding: 2px 6px; border: 1px solid #2a2a34; border-radius: 3px; display: inline-block; }
.mod-wtfs .abbr { color: #4a9eff; }
.mod-wtfs:hover, .mod-wtfs.selected { border-color: #4a9eff; box-shadow: 0 0 24px rgba(74,158,255,0.15); }
.mod-dtf .abbr { color: #ff8c42; }
.mod-dtf:hover, .mod-dtf.selected { border-color: #ff8c42; box-shadow: 0 0 24px rgba(255,140,66,0.15); }
.mod-btau .abbr { color: #06d6a0; }
.mod-btau:hover, .mod-btau.selected { border-color: #06d6a0; box-shadow: 0 0 24px rgba(6,214,160,0.15); }
.mod-dd .abbr { color: #c084fc; }
.mod-dd:hover, .mod-dd.selected { border-color: #c084fc; box-shadow: 0 0 24px rgba(192,132,252,0.15); }
.system-bar { display: flex; gap: 20px; padding: 10px 20px; background: #1c1c22; border-radius: 6px; border: 1px solid #2a2a34; font-size: 11px; color: #6b6b78; animation: lfgFadeIn 0.6s ease-out 0.6s both; }
.system-bar .val { color: #a0a0b0; font-weight: 600; }
.links { margin-top: 16px; display: flex; gap: 16px; animation: lfgFadeIn 0.6s ease-out 0.7s both; }
.links a { font-size: 11px; color: #4a4a56; text-decoration: none; cursor: pointer; transition: color 0.15s; }
.links a:hover { color: #4a9eff; }
.version { margin-top: 14px; font-size: 10px; color: #3a3a44; animation: lfgFadeIn 0.6s ease-out 0.8s both; }
.loading-bar { width: 220px; height: 3px; background: #1e1e28; border-radius: 2px; margin: 20px auto 0; overflow: hidden; display: none; }
.loading-bar.active { display: block; }
.loading-fill { height: 100%; width: 0%; border-radius: 2px; transition: width 0.7s cubic-bezier(0.22, 1, 0.36, 1); }
.loading-label { margin-top: 8px; font-size: 11px; color: #6b6b78; display: none; }
.loading-label.active { display: block; }
</style>
</head>
<body>
  <div class=\"splash\">
    <div class=\"logo\"><span>L</span>F<span>G</span></div>
    <div class=\"tagline\">Local File Guardian</div>

    <div class=\"modules\">
      <div class=\"module mod-wtfs\" onclick=\"selectModule('wtfs', this)\" data-tip=\"Scan disk usage in ~/Developer\">
        <div class=\"icon\">&#x1F50D;</div>
        <div class=\"name\">WTFS</div>
        <div class=\"abbr\">Where\\'s The Free Space</div>
        <div class=\"desc\">Disk usage analysis with visual breakdown by directory</div>
        <div class=\"kbd-hint\">&#x2318;1</div>
      </div>
      <div class=\"module mod-dtf\" onclick=\"selectModule('dtf', this)\" data-tip=\"Scan and clean developer caches\">
        <div class=\"icon\">&#x1F5D1;</div>
        <div class=\"name\">DTF</div>
        <div class=\"abbr\">Delete Temp Files</div>
        <div class=\"desc\">Cache discovery and cleanup across dev, build, and system</div>
        <div class=\"kbd-hint\">&#x2318;2</div>
      </div>
      <div class=\"module mod-btau\" onclick=\"selectModule('btau', this)\" data-tip=\"Manage backups and devdrive volumes\">
        <div class=\"icon\">&#x1F4E6;</div>
        <div class=\"name\">BTAU</div>
        <div class=\"abbr\">Back That App Up</div>
        <div class=\"desc\">Backup, transfer, and archive with sparse image management</div>
        <div class=\"kbd-hint\">&#x2318;3</div>
      </div>
      <div class=\"module mod-dd\" onclick=\"selectModule('devdrive', this)\" data-tip=\"Manage symlink forest and developer drive volumes\">
        <div class=\"icon\">&#x1F4BE;</div>
        <div class=\"name\">DEVDRIVE</div>
        <div class=\"abbr\">Developer Drive</div>
        <div class=\"desc\">Symlink forest management across external volumes</div>
        <div class=\"kbd-hint\">&#x2318;4</div>
      </div>
    </div>

    <div class=\"system-bar\">
      <span>Disk Free: <span class=\"val\">''' + '$DISK_FREE' + '''</span></span>
      <span>Used: <span class=\"val\">''' + '$DISK_USED' + '''</span></span>
      <span>''' + '$TIMESTAMP' + '''</span>
    </div>

    <div class=\"links\">
      <a onclick=\"selectModule('dashboard', null)\" data-tip=\"Combined view of all modules\">Full Dashboard</a>
      <a onclick=\"window.open('http://localhost:3031')\" data-tip=\"CCEM APM performance monitor\">APM Monitor</a>
    </div>

    <div class=\"version\">lfg v1.0.0 - @yj tools</div>

    <div id=\"loading\" class=\"loading-bar\"><div id=\"loading-fill\" class=\"loading-fill\"></div></div>
    <div id=\"loading-label\" class=\"loading-label\">Loading module...</div>
  </div>

  <script>
''' + ui_js + '''

  LFG.init({ context: \"Select a Module\", moduleVersion: \"1.0.0\", welcome: \"Select a module to get started\" });

  // Keyboard shortcuts
  document.addEventListener('keydown', function(e) {
    if (e.metaKey && e.key === '1') selectModule('wtfs', document.querySelector('.mod-wtfs'));
    if (e.metaKey && e.key === '2') selectModule('dtf', document.querySelector('.mod-dtf'));
    if (e.metaKey && e.key === '3') selectModule('btau', document.querySelector('.mod-btau'));
    if (e.metaKey && e.key === '4') selectModule('devdrive', document.querySelector('.mod-dd'));
    if (e.metaKey && e.key === 'd') selectModule('dashboard', null);
  });

  function selectModule(name, el) {
    document.querySelectorAll('.module').forEach(function(m) { m.style.opacity = '0.4'; });
    if (el) { el.classList.add('selected'); el.style.opacity = '1'; }

    var colors = { wtfs: '#4a9eff', dtf: '#ff8c42', btau: '#06d6a0', devdrive: '#c084fc', dashboard: '#4a9eff' };
    var labels = { wtfs: 'Scanning disk...', dtf: 'Scanning caches...', btau: 'Checking backups...', devdrive: 'Loading devdrive...', dashboard: 'Loading dashboard...' };
    var fill = document.getElementById('loading-fill');
    var bar = document.getElementById('loading');
    var label = document.getElementById('loading-label');

    fill.style.background = colors[name] || '#4a9eff';
    bar.classList.add('active');
    label.classList.add('active');
    label.textContent = labels[name] || 'Loading...';

    LFG.toast('Launching ' + name.toUpperCase() + '...', { type: 'info', duration: 2000 });

    requestAnimationFrame(function() { fill.style.width = '100%'; });

    window.webkit.messageHandlers.lfg.postMessage({ action: 'select', module: name });
  }
  </script>
</body>
</html>'''

open('$HTML_FILE', 'w').write(html)
"

# Launch viewer with --select flag
"$VIEWER" "$HTML_FILE" "LFG - Local File Guardian" --select "$SELECT_FILE" &
VIEWER_PID=$!

# Wait for selection or viewer close
SELECTION=""
while kill -0 "$VIEWER_PID" 2>/dev/null; do
    if [[ -s "$SELECT_FILE" ]]; then
        SELECTION=$(cat "$SELECT_FILE")
        break
    fi
    sleep 0.2
done

rm -f "$SELECT_FILE"
wait "$VIEWER_PID" 2>/dev/null || true

# Launch selected module
case "$SELECTION" in
    wtfs)      exec "$LFG_DIR/lib/scan.sh" ;;
    dtf)       exec "$LFG_DIR/lib/clean.sh" ;;
    btau)      exec "$LFG_DIR/lib/btau.sh" --view ;;
    devdrive)  exec "$LFG_DIR/lib/devdrive.sh" ;;
    dashboard) exec "$LFG_DIR/lib/dashboard.sh" ;;
    *)         exit 0 ;;
esac

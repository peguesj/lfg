#!/usr/bin/env bash
# lfg dtf - Delete Temp Files (cache cleaner with WebKit report + cross-module integration)
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIEWER="$LFG_DIR/viewer"

source "$LFG_DIR/lib/state.sh"
LFG_MODULE="dtf"
HTML_FILE="$LFG_CACHE_DIR/.lfg_clean.html"
source "$LFG_DIR/lib/settings.sh" 2>/dev/null || true
lfg_state_start dtf

FORCE=false
INCLUDE_DOCKER=false
USE_SUDO=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)    FORCE=true ;;
        --docker)   INCLUDE_DOCKER=true ;;
        --sudo)     USE_SUDO=true ;;
        --only)     ONLY_NAME="$2"; shift ;;
        --only=*)   ONLY_NAME="${1#--only=}" ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
    shift
done

get_size_kb() { [[ -e "$1" ]] && du -sk "$1" 2>/dev/null | awk '{print $1}' || echo 0; }
format_size() {
    local kb="$1"
    if (( kb >= 1048576 )); then awk "BEGIN{printf \"%.1f GB\", $kb/1048576}"
    elif (( kb >= 1024 )); then awk "BEGIN{printf \"%.1f MB\", $kb/1024}"
    elif (( kb > 0 )); then echo "${kb} KB"
    else echo "0"
    fi
}

CACHES=(
    "DEV|npm cache|$HOME/.npm|"
    "DEV|pip cache||pip3 cache purge 2>/dev/null"
    "DEV|uv cache|$HOME/.cache/uv|"
    "DEV|Cargo registry|$HOME/.cargo/registry|"
    "DEV|Homebrew downloads|$HOME/Library/Caches/Homebrew|"
    "DEV|Homebrew cleanup||brew cleanup --prune=all -s 2>/dev/null"
    "DEV|Go module cache||go clean -modcache 2>/dev/null"
    "DEV|Gradle cache|$HOME/.gradle/caches|"
    "DEV|Maven repository|$HOME/.m2/repository|"
    "DEV|CocoaPods cache|$HOME/Library/Caches/CocoaPods|"
    "DEV|Yarn cache|$HOME/Library/Caches/Yarn|"
    "DEV|pnpm store|$HOME/Library/pnpm/store|"
    "BUILD|Puppeteer browsers|$HOME/.cache/puppeteer|"
    "BUILD|Playwright browsers|$HOME/Library/Caches/ms-playwright|"
    "BUILD|Chrome DevTools MCP|$HOME/.cache/chrome-devtools-mcp|"
    "BUILD|Electron cache|$HOME/Library/Caches/electron|"
    "BUILD|TypeScript cache|$HOME/Library/Caches/typescript|"
    "BUILD|Node cache|$HOME/.cache/node|"
    "BUILD|Prisma engines|$HOME/.cache/prisma|"
    "BUILD|Turbo cache|$HOME/Library/Caches/turbo|"
    "BUILD|Next.js cache|$HOME/.next/cache|"
    "APP|Google Chrome|$HOME/Library/Caches/Google|"
    "APP|Microsoft Edge|$HOME/Library/Caches/Microsoft Edge|"
    "APP|Brave|$HOME/Library/Caches/BraveSoftware|"
    "APP|Spotify|$HOME/Library/Caches/com.spotify.client|"
    "APP|Splice|$HOME/Library/Caches/com.splice.Splice|"
    "APP|OpenAI Atlas|$HOME/Library/Caches/com.openai.atlas|"
    "APP|ChatGPT|$HOME/Library/Caches/com.openai.chat|"
    "APP|Ollama|$HOME/Library/Caches/ollama|"
    "APP|VS Code|$HOME/Library/Caches/com.microsoft.VSCode.ShipIt|"
    "APP|Notion|$HOME/Library/Caches/notion.id.ShipIt|"
    "APP|Linear|$HOME/Library/Caches/@lineardesktop-updater|"
    "APP|Adobe caches|$HOME/Library/Caches/Adobe|"
    "APP|Limitless|$HOME/Library/Caches/ai.limitless.desktop|"
    "APP|iMazing|$HOME/Library/Caches/iMazing|"
    "SYS|Adobe logs|$HOME/Library/Logs/Adobe|"
    "SYS|CreativeCloud logs|$HOME/Library/Logs/CreativeCloud|"
    "SYS|Claude logs|$HOME/Library/Logs/Claude|"
    "SYS|Limitless logs|$HOME/Library/Logs/ai.limitless.desktop|"
    "SYS|Xcode DerivedData|$HOME/Library/Developer/Xcode/DerivedData|"
    "SYS|Saved App State|$HOME/Library/Saved Application State|"
)

TOTAL_RECLAIMABLE=0
TOTAL_FREED=0
CLEANED=0
SKIPPED=0
ERRORS=0
ROWS=""

echo "Scanning caches..."

ONLY_NAME="${ONLY_NAME:-}"

for entry in "${CACHES[@]}"; do
    IFS='|' read -r cat name path cmd <<< "$entry"

    # --only filter
    [[ -n "$ONLY_NAME" ]] && [[ "$name" != "$ONLY_NAME" ]] && continue

    if [[ -z "$path" ]]; then
        size_kb=0; status="badge-skipped"; status_text="CMD"
        if [[ "$FORCE" == "true" ]] && command -v "$(echo "$cmd" | awk '{print $1}')" &>/dev/null; then
            if eval "$cmd" &>/dev/null; then status="badge-cleaned"; status_text="RAN"; CLEANED=$((CLEANED + 1)); fi
        fi
    elif [[ ! -e "$path" ]]; then
        size_kb=0; status="badge-skipped"; status_text="N/A"; SKIPPED=$((SKIPPED + 1))
    else
        size_kb=$(get_size_kb "$path")
        if (( size_kb == 0 )); then
            status="badge-skipped"; status_text="EMPTY"; SKIPPED=$((SKIPPED + 1))
        elif [[ "$FORCE" == "true" ]]; then
            TOTAL_RECLAIMABLE=$((TOTAL_RECLAIMABLE + size_kb))
            echo "  Cleaning $name ($(format_size $size_kb))..."
            [[ -n "$cmd" ]] && eval "$cmd" &>/dev/null || true
            rm -rf "$path" 2>/dev/null || true
            [[ "$USE_SUDO" == "true" ]] && [[ -e "$path" ]] && sudo rm -rf "$path" 2>/dev/null || true
            size_after=$(get_size_kb "$path")
            freed=$((size_kb - size_after))
            TOTAL_FREED=$((TOTAL_FREED + freed))
            if (( freed > 0 )); then status="badge-cleaned"; status_text="FREED $(format_size $freed)"; CLEANED=$((CLEANED + 1))
            else status="badge-error"; status_text="LOCKED"; ERRORS=$((ERRORS + 1)); fi
        else
            TOTAL_RECLAIMABLE=$((TOTAL_RECLAIMABLE + size_kb))
            status="badge-pending"; status_text="$(format_size $size_kb)"
        fi
    fi

    (( size_kb == 0 )) && [[ "$status_text" == "N/A" || "$status_text" == "EMPTY" || "$status_text" == "CMD" ]] && [[ "$FORCE" != "true" ]] && continue

    size_display=$(format_size "$size_kb")
    cat_class="cat-$(echo "$cat" | tr '[:upper:]' '[:lower:]')"

    if (( TOTAL_RECLAIMABLE > 0 && size_kb > 0 )); then
        bar_w=$(awk "BEGIN{printf \"%.1f\", ($size_kb/$TOTAL_RECLAIMABLE)*100}")
    else bar_w="0"; fi

    # Escape path for JS
    path_esc=$(echo "$path" | sed "s/'/\\\\'/g")
    clean_cmd=""
    if [[ -n "$path" ]] && (( size_kb > 0 )); then
        clean_cmd="rm -rf '${path_esc}'"
    elif [[ -n "$cmd" ]]; then
        clean_cmd="$cmd"
    fi

    ROWS+="<tr data-tip=\"${name}: ${size_display} [${cat}]\">
      <td><span class=\"cat ${cat_class}\">${cat}</span></td>
      <td class=\"name\">${name}</td>
      <td class=\"size\">${size_display}</td>
      <td class=\"bar-cell\"><div class=\"bar-track\"><div class=\"bar-fill\" style=\"width:${bar_w}%;background:var(--bar-color,#4a9eff)\"></div></div></td>
      <td><span class=\"status-badge ${status}\">${status_text}</span></td>
      <td class=\"action-cell\">"
    if [[ -n "$clean_cmd" ]] && (( size_kb > 0 )) && [[ "$FORCE" != "true" ]]; then
        ROWS+="<button class=\"action-btn-sm\" onclick=\"LFG.confirm('Clean ${name}? (${size_display})', '${clean_cmd}', function(o,e,c){ if(c===0) LFG.toast('Cleaned ${name}',{type:'success'}); else LFG.toast('Failed: '+e,{type:'error'}); })\">Clean</button>"
    fi
    ROWS+="</td></tr>"
done

DISK_FREE=$(df -h / | awk 'NR==2{print $4}')
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

if [[ "$FORCE" == "true" ]]; then
    MODE_LABEL="Cleaned"; TOTAL_DISPLAY=$(format_size $TOTAL_FREED); TOTAL_CLASS="good"
else
    MODE_LABEL="Reclaimable"; TOTAL_DISPLAY=$(format_size $TOTAL_RECLAIMABLE); TOTAL_CLASS="warn"
fi

MODE_TAG=$([ "$FORCE" == "true" ] && echo "[executed]" || echo "[dry run]")
FOOTER_MSG=$([ "$FORCE" == "true" ] && echo "Freed ${TOTAL_DISPLAY}" || echo "Run: lfg dtf --force")

python3 -c "
theme = open('$LFG_DIR/lib/theme.css').read()
uijs = open('$LFG_DIR/lib/ui.js').read()
rows = '''$ROWS'''

html = '''<!DOCTYPE html>
<html><head><meta charset=\"utf-8\">
<style>''' + theme + '''</style>
</head><body>
  <div class=\"summary\">
    <div class=\"stat\" data-tip=\"Total $MODE_LABEL space\"><span class=\"label\">$MODE_LABEL</span><span class=\"value $TOTAL_CLASS\">$TOTAL_DISPLAY</span></div>
    <div class=\"stat\" data-tip=\"Current free disk space\"><span class=\"label\">Disk Free</span><span class=\"value accent\">$DISK_FREE</span></div>
    <div class=\"stat\" data-tip=\"Caches successfully cleaned\"><span class=\"label\">Cleaned</span><span class=\"value\">$CLEANED</span></div>
    <div class=\"stat\" data-tip=\"Caches not found or empty\"><span class=\"label\">Skipped</span><span class=\"value\">$SKIPPED</span></div>
  </div>
  <table id=\"main-table\">
    <thead><tr><th>Cat</th><th>Cache</th><th class=\"r\">Size</th><th>Share</th><th>Status</th><th></th></tr></thead>
    <tbody>''' + rows + '''</tbody>
  </table>
  <div id=\"action-bar\"></div>
  <div class=\"footer\">lfg dtf - Local File Guardian | $FOOTER_MSG</div>
  <script>''' + uijs + '''
  LFG.init({ module: \"dtf\", context: \"$MODE_TAG\", moduleVersion: \"2.4.0\", welcome: \"$MODE_LABEL: $TOTAL_DISPLAY across caches\", helpContent: \"<strong>DTF</strong> scans developer, build, application, and system caches.<br><br>''' + ('Run <code>lfg dtf --force</code> to actually clean these caches.' if '$FORCE' == 'false' else 'Cleanup complete. Run <code>lfg wtfs</code> to see updated disk usage.') + '''<br><br><strong>Selection:</strong> Click rows to select, Shift+click for range, Cmd+click to toggle.\" });
  LFG.select.init('main-table');
  document.getElementById(\"action-bar\").appendChild(
    LFG.createCommandPanel(\"DTF Actions\", [
      { label: \"Scan Only\", desc: \"Dry run - show reclaimable\", cli: \"lfg dtf\", module: \"dtf\", action: \"run\", color: \"#4a9eff\" },
      { label: \"Clean All\", desc: \"Delete all scanned caches\", cli: \"lfg dtf --force\", module: \"dtf\", action: \"run\", args: \"--force\", color: \"#ff8c42\" },
      { label: \"Clean + Docker\", desc: \"Caches + Docker prune\", cli: \"lfg dtf --force --docker\", module: \"dtf\", action: \"run\", args: \"--force --docker\", color: \"#ff4d6a\" },
      { label: \"Clean + Sudo\", desc: \"Caches + privileged cleanup\", cli: \"lfg dtf --force --sudo\", module: \"dtf\", action: \"run\", args: \"--force --sudo\", color: \"#ff4d6a\" },
      { label: \"Nuclear\", desc: \"Everything: caches + Docker + sudo\", cli: \"lfg dtf --force --docker --sudo\", module: \"dtf\", action: \"run\", args: \"--force --docker --sudo\", color: \"#ff4d6a\" },
    ])
  );
  document.getElementById(\"action-bar\").appendChild(
    LFG.createActionBar([
      { label: \"Disk Usage\", color: \"#4a9eff\", onclick: function(){ LFG._postNav('navigate', {target:'wtfs'}); }, tip: \"Navigate to WTFS\" },
      { label: \"View Backups\", color: \"#06d6a0\", onclick: function(){ LFG._postNav('navigate', {target:'btau'}); }, tip: \"Navigate to BTAU\" },
      { label: \"Devdrive\", color: \"#c084fc\", onclick: function(){ LFG._postNav('navigate', {target:'devdrive'}); }, tip: \"Navigate to DEVDRIVE\" },
      { label: \"Full Dashboard\", color: \"#4a9eff\", onclick: function(){ LFG._postNav('navigate', {target:'dashboard'}); }, tip: \"Navigate to Dashboard\" },
    ])
  );
  </script>
</body></html>'''

open('$HTML_FILE', 'w').write(html)
"

if [[ "$FORCE" == "true" ]]; then
    lfg_state_done dtf "freed=$TOTAL_DISPLAY" "cleaned=$CLEANED" "mode=force"
else
    lfg_state_done dtf "reclaimable=$TOTAL_DISPLAY" "cleaned=$CLEANED" "skipped=$SKIPPED" "mode=scan"
fi

if [[ "${LFG_NO_VIEWER:-}" == "1" ]]; then
    echo "Done (headless)."
else
    CHAIN_FILE="/tmp/.lfg_chain_$$"
    echo "Opening viewer..."
    "$VIEWER" "$HTML_FILE" "LFG DTF - $MODE_LABEL $TOTAL_DISPLAY" --select "$CHAIN_FILE" &
    VPID=$!
    disown
    (
      while kill -0 "$VPID" 2>/dev/null; do
        if [[ -s "$CHAIN_FILE" ]]; then
          SEL=$(cat "$CHAIN_FILE"); rm -f "$CHAIN_FILE"
          case "$SEL" in
            wtfs) "$LFG_DIR/lib/scan.sh" ;; btau) "$LFG_DIR/lib/btau.sh" --view ;; devdrive) "$LFG_DIR/lib/devdrive.sh" ;; dashboard) "$LFG_DIR/lib/dashboard.sh" ;;
          esac; break
        fi; sleep 0.3
      done; rm -f "$CHAIN_FILE"
    ) &
    disown
    echo "Done."
fi

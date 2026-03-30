#!/usr/bin/env bash
# lfg ssd — Slows Sh*t Down: Spotlight exclusion + mds CPU monitor
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VIEWER="$LFG_DIR/viewer"
source "$LFG_DIR/lib/state.sh"
LFG_MODULE="ssd"
HTML_FILE="$LFG_CACHE_DIR/.lfg_ssd.html"
source "$LFG_DIR/lib/settings.sh" 2>/dev/null || true
lfg_state_start ssd

CMD="${1:-status}"; [[ $# -gt 0 ]] && shift || true
FORCE=false
for arg in "$@"; do [[ "$arg" == "--force" ]] && FORCE=true; done

SKIP_VOLS=("Macintosh HD" "Macintosh HD - Data" "Recovery")

# --- helpers ---
mds_cpu() {
    ps aux 2>/dev/null | awk 'NR>1 && $11~/mds/{s+=$3} END{printf "%.1f", s+0}'
}

indexed_volumes() {
    mdutil -a -s 2>/dev/null | grep -B1 "Indexing enabled" | grep "^/" | sed 's/:$//'
}

external_volumes() {
    local vol name skip
    for vol in /Volumes/*/; do
        [[ -d "$vol" ]] || continue
        name=$(basename "$vol")
        skip=false
        for s in "${SKIP_VOLS[@]}"; do [[ "$name" == "$s" ]] && skip=true && break; done
        $skip || echo "$vol"
    done
    for vol in "$HOME/Library/CloudStorage/"/*/; do
        [[ -d "$vol" ]] && echo "$vol"
    done
}

# --- status: show mds CPU + indexed volume summary (WebKit viewer) ---
cmd_status() {
    local cpu; cpu=$(mds_cpu)
    local indexed_list; indexed_list=$(indexed_volumes)
    local indexed; indexed=$(echo "$indexed_list" | grep -c "." 2>/dev/null || echo "0")
    local ext_count; ext_count=$(external_volumes | grep -c "." 2>/dev/null || echo "0")

    lfg_state_update ssd "mds_cpu" "${cpu}%"
    lfg_state_update ssd "indexed_count" "$indexed"

    # CLI output
    echo "=== SSD: Spotlight Status ==="
    printf "mds CPU:         %s%%\n" "$cpu"
    printf "Indexed volumes: %s\n\n" "$indexed"

    # Build volume rows for HTML
    VOLUME_ROWS=""
    while IFS= read -r vol; do
        [[ -z "$vol" ]] && continue
        local vol_path="${vol%/}"
        local name; name=$(basename "$vol_path")
        local status_text="unknown" status_class="muted"
        local idx_status; idx_status=$(mdutil -s "$vol_path" 2>/dev/null | grep -i "index" | head -1 || echo "")
        if echo "$idx_status" | grep -qi "enabled"; then
            status_text="Indexed" status_class="danger"
        elif echo "$idx_status" | grep -qi "disabled"; then
            status_text="Excluded" status_class="good"
        fi
        local is_ext="Internal"
        [[ "$vol_path" == /Volumes/* ]] && is_ext="External"
        [[ "$vol_path" == *CloudStorage* ]] && is_ext="Cloud"
        VOLUME_ROWS+="<tr><td>${name}</td><td style=\"font-size:0.75rem;color:#64748b\">${vol_path}</td><td class=\"${status_class}\">${status_text}</td><td>${is_ext}</td></tr>"
    done < <(printf '%s\n' / /System/Volumes/Data; external_volumes)

    # mds processes for HTML
    MDS_PROCS=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local pid cpu_pct cmd_name
        pid=$(echo "$line" | awk '{print $2}')
        cpu_pct=$(echo "$line" | awk '{print $3}')
        cmd_name=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf "%s ",$i; print ""}')
        MDS_PROCS+="<tr><td>${pid}</td><td>${cpu_pct}%</td><td style=\"font-size:0.75rem\">${cmd_name}</td></tr>"
    done < <(ps aux 2>/dev/null | awk 'NR>1 && $11~/mds/' | grep -v awk)

    # CPU level indicator
    local cpu_class="good" cpu_label="Normal"
    local cpu_int; cpu_int=$(printf "%.0f" "$cpu")
    if [[ "$cpu_int" -ge 50 ]]; then
        cpu_class="danger" cpu_label="Critical"
    elif [[ "$cpu_int" -ge 20 ]]; then
        cpu_class="warn" cpu_label="Elevated"
    fi

    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

    python3 -c "
theme = open('$LFG_DIR/lib/theme.css').read()
uijs = open('$LFG_DIR/lib/ui.js').read()
volume_rows = '''$VOLUME_ROWS'''
mds_procs = '''$MDS_PROCS'''

html = '''<!DOCTYPE html>
<html><head><meta charset=\"utf-8\">
<style>''' + theme + '''
.cpu-bar { height:8px; border-radius:4px; background:#1e293b; margin-top:4px; }
.cpu-fill { height:100%; border-radius:4px; transition: width 0.3s; }
</style>
</head><body>
  <div class=\"summary\">
    <div class=\"stat\" data-tip=\"Combined mds + mds_stores CPU usage\"><span class=\"label\">mds CPU</span><span class=\"value $cpu_class\">${cpu}%</span>
      <div class=\"cpu-bar\"><div class=\"cpu-fill\" style=\"width:min(${cpu}%,100%);background:var(--$cpu_class, #facc15)\"></div></div>
    </div>
    <div class=\"stat\" data-tip=\"CPU status level\"><span class=\"label\">Status</span><span class=\"value $cpu_class\">$cpu_label</span></div>
    <div class=\"stat\" data-tip=\"Volumes with Spotlight indexing enabled\"><span class=\"label\">Indexed</span><span class=\"value warn\">$indexed</span></div>
    <div class=\"stat\" data-tip=\"External + Cloud volumes detected\"><span class=\"label\">External</span><span class=\"value\">$ext_count</span></div>
  </div>

  <div class=\"section-title\" style=\"color:#facc15\">Volume Index Status</div>
  <table><thead><tr><th>Volume</th><th>Path</th><th>Spotlight</th><th>Type</th></tr></thead>
  <tbody>''' + volume_rows + '''</tbody></table>

  <div class=\"section-title\" style=\"color:#facc15\">mds Processes</div>
  <table><thead><tr><th>PID</th><th>CPU</th><th>Command</th></tr></thead>
  <tbody>''' + mds_procs + '''</tbody></table>

  <div id=\"action-bar\"></div>
  <div class=\"footer\">lfg ssd - Slows Sh*t Down | Spotlight Manager | $TIMESTAMP</div>
  <script>''' + uijs + '''
  LFG.init({ module: \"ssd\", context: \"Spotlight Manager\", moduleVersion: \"2.4.1\", welcome: \"mds CPU: ${cpu}% · $indexed indexed volumes\", helpContent: \"<strong>SSD</strong> monitors and manages macOS Spotlight indexing.<br><br>High mds CPU (>20%) usually means Spotlight is re-indexing external volumes. Use <code>lfg ssd exclude --force</code> to disable indexing on external + CloudStorage volumes.<br><br><code>lfg ssd scan</code> to identify candidates, <code>lfg ssd status</code> to check current state.\" });
  document.getElementById(\"action-bar\").appendChild(
    LFG.createCommandPanel(\"SSD Actions\", [
      { label: \"Scan Volumes\", desc: \"Identify volumes causing CPU pressure\", cli: \"lfg ssd scan\", module: \"ssd\", action: \"run\", args: \"scan\", color: \"#facc15\" },
      { label: \"Exclude (Dry Run)\", desc: \"Preview volumes that would be excluded\", cli: \"lfg ssd exclude\", module: \"ssd\", action: \"run\", args: \"exclude\", color: \"#facc15\" },
      { label: \"Exclude (Force)\", desc: \"Disable Spotlight on all external volumes\", cli: \"sudo lfg ssd exclude --force\", module: \"ssd\", action: \"run\", args: \"exclude --force\", color: \"#ef4444\" },
    ])
  );
  document.getElementById(\"action-bar\").appendChild(
    LFG.createActionBar([
      { label: \"Disk Usage\", color: \"#4a9eff\", onclick: function(){ LFG._postNav(\"navigate\", {target:\"wtfs\"}); }, tip: \"Navigate to WTFS\" },
      { label: \"Clean Caches\", color: \"#ff8c42\", onclick: function(){ LFG._postNav(\"navigate\", {target:\"dtf\"}); }, tip: \"Navigate to DTF\" },
      { label: \"DevDrive\", color: \"#c084fc\", onclick: function(){ LFG._postNav(\"navigate\", {target:\"devdrive\"}); }, tip: \"Navigate to DEVDRIVE\" },
      { label: \"Full Dashboard\", color: \"#4a9eff\", onclick: function(){ LFG._postNav(\"navigate\", {target:\"dashboard\"}); }, tip: \"Navigate to Dashboard\" },
    ])
  );
  </script>
</body></html>'''

open('$HTML_FILE', 'w').write(html)
"

    lfg_state_done ssd "mds_cpu=${cpu}%" "indexed_count=$indexed"

    if [[ "${LFG_NO_VIEWER:-}" == "1" ]]; then
        echo "Done (headless)."
    else
        CHAIN_FILE="/tmp/.lfg_chain_$$"
        echo "Opening viewer..."
        "$VIEWER" "$HTML_FILE" "LFG SSD - Spotlight Manager" --select "$CHAIN_FILE" &
        VPID=$!
        disown
        (
          while kill -0 "$VPID" 2>/dev/null; do
            if [[ -s "$CHAIN_FILE" ]]; then
              SEL=$(cat "$CHAIN_FILE"); rm -f "$CHAIN_FILE"
              case "$SEL" in
                wtfs) "$LFG_DIR/lib/scan.sh" ;; dtf) "$LFG_DIR/lib/clean.sh" ;; btau) "$LFG_DIR/lib/btau.sh" --view ;; devdrive) "$LFG_DIR/lib/devdrive.sh" ;; dashboard) "$LFG_DIR/lib/dashboard.sh" ;;
              esac; break
            fi
            sleep 0.5
          done
        ) &
    fi
}

# --- scan: identify which external volumes are causing Spotlight pressure ---
cmd_scan() {
    local cpu; cpu=$(mds_cpu)
    echo "=== SSD: Spotlight Pressure Scan ==="
    printf "mds total CPU: %s%%\n\n" "$cpu"

    echo "--- External volumes ---"
    local candidates=0
    while IFS= read -r vol; do
        local vol_path="${vol%/}"
        local status; status=$(mdutil -s "$vol_path" 2>/dev/null | grep -i "indexing" | head -1 || echo "")
        if echo "$status" | grep -qi "enabled"; then
            printf "  [indexed]  %s\n" "$vol_path"
            candidates=$((candidates + 1))
        else
            printf "  [excluded] %s\n" "$vol_path"
        fi
    done < <(external_volumes)

    echo ""
    printf "Candidates for exclusion: %s\n" "$candidates"
    printf "Run: lfg ssd exclude --force\n"

    lfg_state_update ssd "scan_candidates" "$candidates"
    lfg_state_update ssd "mds_cpu" "${cpu}%"
    lfg_state_done ssd "scan_candidates=$candidates" "mds_cpu=${cpu}%"
}

# --- exclude: disable Spotlight on all external + CloudStorage volumes ---
cmd_exclude() {
    if ! $FORCE; then
        echo "=== SSD: Spotlight Exclusion (dry run) ==="
        echo "Volumes that would be excluded:"
        while IFS= read -r vol; do
            printf "  %s\n" "$vol"
        done < <(external_volumes)
        echo ""
        echo "Run: lfg ssd exclude --force"
        lfg_state_done ssd "mode=dry-run"
        exit 0
    fi

    echo "=== SSD: Disabling Spotlight on external volumes ==="
    local excluded=0
    while IFS= read -r vol; do
        printf "  Disabling: %s ... " "$vol"
        if sudo mdutil -i off "$vol" 2>/dev/null; then
            echo "OK"
            excluded=$((excluded + 1))
        else
            echo "skipped (no sudo or already excluded)"
        fi
    done < <(external_volumes)

    echo ""
    echo "--- Verification ---"
    mdutil -a -s 2>/dev/null | grep -E "^\/" | head -20

    echo ""
    echo "--- mds CPU after ---"
    sleep 2
    local cpu_after; cpu_after=$(mds_cpu)
    printf "mds CPU: %s%%\n" "$cpu_after"

    lfg_state_done ssd "excluded=$excluded" "mds_cpu=${cpu_after}%"
}

case "$CMD" in
    status)  cmd_status ;;
    scan)    cmd_scan ;;
    exclude) cmd_exclude ;;
    *)
        echo "Usage: lfg ssd [status|scan|exclude [--force]]"
        echo ""
        echo "  status   Show mds CPU usage and indexed volume list"
        echo "  scan     Identify external volumes causing Spotlight pressure"
        echo "  exclude  Dry run: list volumes that would be excluded"
        echo "           --force  Disable Spotlight on all external + CloudStorage volumes"
        lfg_state_error ssd "Unknown subcommand: $CMD"
        exit 1
        ;;
esac

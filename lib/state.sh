#!/usr/bin/env bash
# =============================================================================
# lfg state - Shared state management for module monitoring
# =============================================================================
# Modules source this file to report progress/results to ~/.config/lfg/state.json
# The menubar app watches this file for live updates and notifications.
# =============================================================================

readonly LFG_STATE_DIR="$HOME/.config/lfg"
readonly LFG_STATE_FILE="$LFG_STATE_DIR/state.json"
readonly LFG_LOG_FILE="$LFG_STATE_DIR/lfg.log"

# Cache directory: prefer DevDrive to reduce main SSD writes
if [[ -d "/Volumes/900DEVELOPER" ]]; then
    readonly LFG_CACHE_DIR="/Volumes/900DEVELOPER/.lfg-cache"
else
    readonly LFG_CACHE_DIR="${LFG_DIR:-.}"
fi

mkdir -p "$LFG_STATE_DIR" "$LFG_CACHE_DIR" 2>/dev/null || {
    echo "[lfg] WARN: Failed to create dirs, falling back to LFG_DIR" >&2
    LFG_CACHE_DIR="${LFG_DIR:-.}"
}

# Global error trap for module scripts
_lfg_trap_exit() {
    local code=$?
    if [[ $code -ne 0 ]] && [[ -n "${LFG_MODULE:-}" ]]; then
        lfg_state_error "$LFG_MODULE" "Exit code $code at line ${BASH_LINENO[0]:-?}"
        lfg_log "$LFG_MODULE: TRAP exit code=$code line=${BASH_LINENO[0]:-?}"
    fi
}
trap _lfg_trap_exit EXIT

# Initialize state file if missing
[[ -f "$LFG_STATE_FILE" ]] || echo '{"modules":{}}' > "$LFG_STATE_FILE"

# Log to lfg.log + syslog + stderr
lfg_log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') [lfg] $*"
    echo "$msg" >> "$LFG_LOG_FILE"
    logger -t "lfg" "$*" 2>/dev/null
    echo "$msg" >&2
}

# Update module state atomically via python3
# Usage: lfg_state_update <module> <key> <value>
#   lfg_state_update wtfs status running
#   lfg_state_update dtf reclaimable "51.3 MB"
lfg_state_update() {
    local module="$1" key="$2" value="$3"
    python3 -c "
import json, os, time
path = '$LFG_STATE_FILE'
try:
    state = json.load(open(path))
except: state = {'modules': {}}
if 'modules' not in state: state['modules'] = {}
if '$module' not in state['modules']: state['modules']['$module'] = {}
state['modules']['$module']['$key'] = '$value'
state['modules']['$module']['updated_at'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
state['last_updated'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
# Disk stats (APFS-aware: used = total * capacity%, in GB)
import subprocess
df = subprocess.run(['df','/'], capture_output=True, text=True).stdout.split('\n')
if len(df) > 1:
    parts = df[1].split()
    if len(parts) > 4:
        total_gb = int(int(parts[1]) * 512 / 1e9 + 0.5)
        pct = int(parts[4].replace('%',''))
        used_gb = int(total_gb * pct / 100 + 0.5)
        avail_gb = round(int(parts[3]) * 512 / 1e9, 1)
        state['disk_free'] = f'{avail_gb} GB'
        state['disk_used'] = f'{pct}%'
        state['disk_total_gb'] = total_gb
        state['disk_used_gb'] = used_gb
tmp = path + '.tmp'
with open(tmp, 'w') as f: json.dump(state, f, indent=2)
os.replace(tmp, path)
" 2>/dev/null
}

# Send notification to CCEM APM (non-blocking, best-effort)
# Uses --connect-timeout and --max-time so we never block if APM is down
lfg_notify_apm() {
    local title="$1" body="$2" category="${3:-info}" agent_id="${4:-lfg}"
    local payload="{\"title\":\"$title\",\"body\":\"$body\",\"category\":\"$category\",\"agent_id\":\"$agent_id\"}"
    # Notify v3 Python server (port 3031)
    curl -s --connect-timeout 2 --max-time 5 \
        -X POST "http://localhost:3031/api/notifications/add" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        >/dev/null 2>&1 &
    # Also notify v4 Phoenix (port 3032) if running
    curl -s --connect-timeout 2 --max-time 5 \
        -X POST "http://localhost:3032/api/notifications/add" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        >/dev/null 2>&1 &
}

# Set module as running
lfg_state_start() {
    local module="$1"
    lfg_state_update "$module" "status" "running"
    lfg_state_update "$module" "started_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    lfg_log "$module: started"
}

# Set module as completed with summary
lfg_state_done() {
    local module="$1"
    shift
    lfg_state_update "$module" "status" "completed"
    lfg_state_update "$module" "completed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Write any extra key=value pairs
    while [[ $# -gt 0 ]]; do
        local kv="$1"; shift
        local k="${kv%%=*}" v="${kv#*=}"
        lfg_state_update "$module" "$k" "$v"
    done
    lfg_log "$module: completed $*"
    lfg_notify_apm "LFG $module" "Completed: $*" "success" "lfg-$module"
    # Trigger incremental search index update (non-blocking)
    python3 "$(dirname "$0")/search_index.py" update >/dev/null 2>&1 &
}

# Set module as errored
lfg_state_error() {
    local module="$1" msg="$2"
    lfg_state_update "$module" "status" "error"
    lfg_state_update "$module" "error" "$msg"
    lfg_log "$module: ERROR $msg"
    lfg_notify_apm "LFG $module ERROR" "$msg" "error" "lfg-$module"
}

# Read a state value
lfg_state_get() {
    local module="$1" key="$2"
    python3 -c "
import json
try:
    s = json.load(open('$LFG_STATE_FILE'))
    print(s.get('modules',{}).get('$module',{}).get('$key',''))
except: pass
" 2>/dev/null
}

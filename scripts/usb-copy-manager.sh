#!/usr/bin/env bash
# usb-copy-manager.sh — pause/resume ditto USB copy with UUID-based reconnect
# Usage: usb-copy-manager.sh [dry-run|pause|resume|status|smart-copy]
#
# State file: /tmp/usb-copy-state.json
# Approach:
#   pause  — SIGSTOP ditto, save state (complete files, pid, dest UUID)
#   resume — try SIGCONT; if ditto died (bad FDs after reconnect), fall back to smart-copy
#   smart-copy — walk source, skip files that exist in dest with matching size, copy rest

set -euo pipefail

STATE_FILE="/tmp/usb-copy-state.json"
SOURCE_DIR="/Users/jeremiah/Downloads/SurfacePro7_BMR_12010_2025.901.10922483/"
SURFACE_UUID="3CB61154-8C14-3116-8522-6A7E10D63C17"
APM_ENDPOINT="http://localhost:3032/api/notify"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; }

# ── helpers ──────────────────────────────────────────────────────────────────

get_ditto_pid() {
    pgrep -f "ditto.*SurfacePro7" 2>/dev/null | head -1 || true
}

get_surface_mount_by_uuid() {
    # diskutil info "UUID:<uuid>" only works for APFS; FAT32 volumes need disk-scan approach
    # Scan all mounted volumes and match by Volume UUID from diskutil info
    while IFS= read -r dev; do
        local info
        info=$(diskutil info "$dev" 2>/dev/null) || continue
        local vuuid
        vuuid=$(echo "$info" | awk -F': ' '/Volume UUID/{gsub(/^[[:space:]]+/,"",$2); print $2}' | head -1)
        if [[ "$vuuid" == "$SURFACE_UUID" ]]; then
            echo "$info" | awk -F': ' '/Mount Point/{gsub(/^[[:space:]]+/,"",$2); print $2}' \
                | grep -v '^$' | head -1
            return
        fi
    done < <(diskutil list | awk '/^\/dev\//{dev=$1} /Microsoft Basic Data|Windows_FAT/{print dev "s" $NF}' \
        | sed 's|/dev/||; s|/dev/||' | awk '{print "/dev/" $1}')
    true
}

post_apm() {
    local event="$1" payload="$2"
    curl -sf -X POST "$APM_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "{\"source\":\"lfg-usb-monitor\",\"event\":\"${event}\",\"project\":\"lfg\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"data\":${payload}}" \
        >/dev/null 2>&1 || true
}

# ── calculate complete files ──────────────────────────────────────────────────

calc_complete_files() {
    local dest_root="$1"
    python3 - "$SOURCE_DIR" "$dest_root" <<'PYEOF'
import os, sys, json

source = sys.argv[1].rstrip("/")
dest   = sys.argv[2].rstrip("/")

complete = []
missing  = []
partial  = []

for root, dirs, files in os.walk(source):
    # Sort for deterministic order
    dirs.sort(); files.sort()
    for fname in files:
        src_path = os.path.join(root, fname)
        rel      = os.path.relpath(src_path, source)
        dst_path = os.path.join(dest, rel)
        src_size = os.path.getsize(src_path)

        if os.path.isfile(dst_path):
            dst_size = os.path.getsize(dst_path)
            if dst_size == src_size:
                complete.append({"rel": rel, "bytes": src_size})
            else:
                partial.append({"rel": rel, "src_bytes": src_size, "dst_bytes": dst_size})
        else:
            missing.append({"rel": rel, "bytes": src_size})

done_bytes    = sum(f["bytes"] for f in complete)
missing_bytes = sum(f["bytes"] for f in missing) + sum(f["src_bytes"] for f in partial)
total_bytes   = done_bytes + missing_bytes

result = {
    "complete": complete,
    "partial":  partial,
    "missing":  missing,
    "done_bytes":    done_bytes,
    "missing_bytes": missing_bytes,
    "total_bytes":   total_bytes,
    "pct": round(done_bytes * 100.0 / total_bytes, 1) if total_bytes > 0 else 0
}
print(json.dumps(result))
PYEOF
}

# ── smart copy (resume engine) ────────────────────────────────────────────────

smart_copy() {
    local dest_root="$1"
    log "Smart copy: ${SOURCE_DIR} -> ${dest_root}"

    python3 - "$SOURCE_DIR" "$dest_root" <<'PYEOF'
import os, sys, subprocess, json

source = sys.argv[1].rstrip("/")
dest   = sys.argv[2].rstrip("/")

skipped = 0; copied = 0; errors = 0

for root, dirs, files in os.walk(source):
    dirs.sort(); files.sort()
    # Remove hidden macOS temp files from dest before copying
    dest_root_dir = os.path.join(dest, os.path.relpath(root, source))
    if os.path.isdir(dest_root_dir):
        for f in os.listdir(dest_root_dir):
            if f.startswith("._") or (f.startswith(".") and f != ".fseventsd" and f != ".Spotlight-V100"):
                try: os.unlink(os.path.join(dest_root_dir, f))
                except: pass

    for fname in files:
        src_path = os.path.join(root, fname)
        rel      = os.path.relpath(src_path, source)
        dst_path = os.path.join(dest, rel)
        src_size = os.path.getsize(src_path)

        if os.path.isfile(dst_path) and os.path.getsize(dst_path) == src_size:
            skipped += 1
            continue

        os.makedirs(os.path.dirname(dst_path), exist_ok=True)
        print(f"  COPY  {rel}  ({src_size/1_048_576:.1f} MB)")

        r = subprocess.run(["ditto", src_path, dst_path], capture_output=True)
        if r.returncode == 0:
            copied += 1
        else:
            print(f"  ERROR {rel}: {r.stderr.decode().strip()}", file=sys.stderr)
            errors += 1

print(f"\nDone: {copied} copied, {skipped} skipped, {errors} errors")
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# COMMANDS
# ─────────────────────────────────────────────────────────────────────────────

cmd_dry_run() {
    log "DRY RUN — logic test (no signals sent)"
    local mount
    mount=$(get_surface_mount_by_uuid)

    if [[ -z "$mount" ]]; then
        err "SURFACE not mounted (UUID: ${SURFACE_UUID})"
        exit 1
    fi

    log "SURFACE found at: ${mount}"
    log "Calculating complete vs remaining files..."

    local info
    info=$(calc_complete_files "$mount")

    python3 - "$info" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
print(f"\n  Complete files : {len(d['complete'])}  ({d['done_bytes']/1_073_741_824:.2f} GB)")
print(f"  Partial files  : {len(d['partial'])}")
print(f"  Missing files  : {len(d['missing'])}")
print(f"  Remaining      : {d['missing_bytes']/1_073_741_824:.2f} GB")
print(f"  Progress       : {d['pct']}%")
print("\n  Would skip:")
for f in d['complete'][:10]:
    print(f"    ✓  {f['rel']}")
if len(d['complete']) > 10:
    print(f"    ... and {len(d['complete'])-10} more")
print("\n  Would copy:")
for f in (d['missing'] + d['partial'])[:10]:
    print(f"    →  {f['rel']}")
if len(d['missing']) + len(d['partial']) > 10:
    print(f"    ... and {len(d['missing'])+len(d['partial'])-10} more")
print("\nDRY RUN PASSED — logic verified, no changes made")
PYEOF
}

cmd_dry_run_2() {
    log "DRY RUN 2 — actual SIGSTOP/SIGCONT (no disconnect)"
    local pid
    pid=$(get_ditto_pid)

    if [[ -z "$pid" ]]; then
        err "ditto not running"
        exit 1
    fi

    log "ditto PID: ${pid}"

    # Verify ditto is writing before pause
    local before_bytes
    before_bytes=$(df /Volumes/SURFACE/ 2>/dev/null | awk 'NR==2{print $3*512}' || echo 0)
    log "Bytes before pause: ${before_bytes}"

    log "Sending SIGSTOP to PID ${pid}..."
    kill -SIGSTOP "$pid"

    sleep 3

    # Verify no writes happened during pause
    local during_bytes
    during_bytes=$(df /Volumes/SURFACE/ 2>/dev/null | awk 'NR==2{print $3*512}' || echo 0)
    log "Bytes during pause (should match before): ${during_bytes}"

    if [[ "$during_bytes" -gt "$((before_bytes + 1048576))" ]]; then
        log "WARNING: bytes grew during SIGSTOP — may have been buffered writes"
    else
        log "OK: no significant writes during pause"
    fi

    log "Sending SIGCONT to PID ${pid}..."
    kill -SIGCONT "$pid"

    sleep 2

    # Verify ditto is still running and writing
    if kill -0 "$pid" 2>/dev/null; then
        local after_bytes
        after_bytes=$(df /Volumes/SURFACE/ 2>/dev/null | awk 'NR==2{print $3*512}' || echo 0)
        log "Bytes after resume: ${after_bytes}"
        log "DRY RUN 2 PASSED — ditto survived SIGSTOP/SIGCONT (still PID ${pid})"
        post_apm "usb_dry_run_2_passed" "{\"pid\":${pid},\"before_bytes\":${before_bytes},\"after_bytes\":${after_bytes}}"
    else
        err "ditto died after SIGCONT — smart-copy fallback will be used on real resume"
        post_apm "usb_dry_run_2_ditto_died" "{\"pid\":${pid}}"
        exit 2
    fi
}

cmd_pause() {
    local pid
    pid=$(get_ditto_pid)

    if [[ -z "$pid" ]]; then
        err "ditto not running"
        exit 1
    fi

    local mount
    mount=$(get_surface_mount_by_uuid)
    [[ -z "$mount" ]] && mount="/Volumes/SURFACE"

    log "Pausing ditto PID ${pid}..."

    # Calculate and save complete files before freezing
    log "Recording complete files..."
    local file_info
    file_info=$(calc_complete_files "$mount" 2>/dev/null || echo '{}')

    # Get current write target from lsof
    local current_write
    current_write=$(lsof -p "$pid" 2>/dev/null \
        | awk '$4 ~ /[0-9]+w$/{print $NF}' \
        | grep -i "SURFACE" | head -1 || true)

    python3 - "$pid" "$mount" "$current_write" "$file_info" <<PYEOF
import json, sys, os

pid, mount, current_write, file_info_str = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

try:
    file_info = json.loads(file_info_str)
except:
    file_info = {}

state = {
    "pid": int(pid),
    "source": "$SOURCE_DIR",
    "dest_mount": mount,
    "dest_uuid": "$SURFACE_UUID",
    "current_write": current_write,
    "paused_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "complete_files": [f["rel"] for f in file_info.get("complete", [])],
    "done_bytes": file_info.get("done_bytes", 0),
    "total_bytes": file_info.get("total_bytes", 0),
    "pct": file_info.get("pct", 0)
}

with open("$STATE_FILE", "w") as f:
    json.dump(state, f, indent=2)

print(f"State saved: {len(state['complete_files'])} complete files, {state['pct']}% done")
print(f"Current write: {current_write or 'unknown'}")
PYEOF

    kill -SIGSTOP "$pid"
    log "ditto SIGSTOP sent — copy paused"

    post_apm "usb_copy_paused" "{\"pid\":${pid},\"state_file\":\"${STATE_FILE}\"}"
    echo "PAUSED:${pid}"
}

cmd_resume() {
    if [[ ! -f "$STATE_FILE" ]]; then
        err "No state file at ${STATE_FILE} — cannot resume"
        exit 1
    fi

    local pid dest_uuid
    pid=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['pid'])")
    dest_uuid=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['dest_uuid'])")

    # Find drive by UUID
    local mount
    mount=$(diskutil info "UUID:${dest_uuid}" 2>/dev/null \
        | awk -F': ' '/Mount Point/{gsub(/^[[:space:]]+/,"",$2); print $2}' \
        | grep -v '^$' | head -1 || true)

    if [[ -z "$mount" ]]; then
        log "Drive not mounted yet (UUID: ${dest_uuid}) — waiting..."
        echo "WAITING"
        exit 2
    fi

    log "Drive found at: ${mount}"

    # Try SIGCONT first
    if kill -0 "$pid" 2>/dev/null; then
        log "Sending SIGCONT to PID ${pid}..."
        kill -SIGCONT "$pid"
        sleep 3

        if kill -0 "$pid" 2>/dev/null; then
            log "ditto resumed successfully (PID ${pid} still alive)"
            post_apm "usb_copy_resumed" "{\"pid\":${pid},\"method\":\"sigcont\",\"mount\":\"${mount}\"}"
            echo "RESUMED_SIGCONT:${pid}"
            exit 0
        else
            log "ditto died after SIGCONT (expected — USB FDs invalidated on disconnect)"
        fi
    else
        log "ditto PID ${pid} already gone — skipping SIGCONT"
    fi

    # Fallback: smart copy
    log "Falling back to smart-copy resume..."
    post_apm "usb_copy_smart_resume_start" "{\"mount\":\"${mount}\"}"
    smart_copy "$mount"
    post_apm "usb_copy_smart_resume_done" "{\"mount\":\"${mount}\"}"
    echo "RESUMED_SMART_COPY"
}

cmd_status() {
    local pid mount
    pid=$(get_ditto_pid)
    mount=$(get_surface_mount_by_uuid)

    echo "ditto PID    : ${pid:-not running}"
    echo "SURFACE mount: ${mount:-not found (UUID: ${SURFACE_UUID})}"

    if [[ -f "$STATE_FILE" ]]; then
        echo "State file   : ${STATE_FILE}"
        python3 -c "
import json
d = json.load(open('$STATE_FILE'))
print(f\"  paused_at  : {d.get('paused_at','?')}\")
print(f\"  progress   : {d.get('pct','?')}%\")
print(f\"  done_bytes : {d.get('done_bytes',0)/1_073_741_824:.2f} GB\")
print(f\"  complete   : {len(d.get('complete_files',[]))} files\")
"
    else
        echo "State file   : none"
    fi

    if [[ -n "$pid" ]]; then
        local state
        state=$(ps -p "$pid" -o state= 2>/dev/null | tr -d ' ' || echo "?")
        echo "ditto state  : ${state} (T=stopped, S=sleeping, R=running, U=uninterruptible)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

case "${1:-status}" in
    dry-run)      cmd_dry_run ;;
    dry-run-2)    cmd_dry_run_2 ;;
    pause)        cmd_pause ;;
    resume)       cmd_resume ;;
    status)       cmd_status ;;
    smart-copy)   mount=$(get_surface_mount_by_uuid); smart_copy "${mount:-/Volumes/SURFACE}" ;;
    *)            echo "Usage: $0 [dry-run|dry-run-2|pause|resume|status|smart-copy]"; exit 1 ;;
esac

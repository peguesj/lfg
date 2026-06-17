#!/usr/bin/env bash
# devdrive-automount.sh — Fleet-aware DevDrive automount helper.
# Triggered by io.lfg.devdrive-automount LaunchAgent on login and when
# any external host volume mounts (via WatchPaths in the plist).
#
# Subcommands:
#   (none)            Normal automount run — mounts all fleet volumes.
#   sync-plist [--dry-run]  Re-write WatchPaths in the automount LaunchAgent plist
#                          from fleet.json external_hosts, then reload the agent.
#   stop-keepawake    Kill any running keep-awake ping loops.
set -uo pipefail

LOG_DIR="$HOME/.config/lfg"
LOG="$LOG_DIR/automount.log"
FLEET_FILE="$HOME/DevDrive/fleet.json"
DEVDRIVE_HOME="$HOME/DevDrive"
AUTOMOUNT_PLIST="$HOME/Library/LaunchAgents/io.lfg.devdrive-automount.plist"
KEEPAWAKE_PID_FILE="$LOG_DIR/keepawake.pid"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$LOG_DIR" "$DEVDRIVE_HOME" 2>/dev/null

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [automount] $*" >> "$LOG"; }

# ---------------------------------------------------------------------------
# sync-plist subcommand
# Re-writes the WatchPaths array in the automount LaunchAgent plist so it
# contains /Volumes plus any host-specific subpaths derived from fleet.json
# external_hosts entries, then reloads the LaunchAgent.
#
# Options:
#   --dry-run   Print the proposed plist diff without writing or reloading.
# ---------------------------------------------------------------------------
cmd_sync_plist() {
    local dry_run=0
    if [[ "${1:-}" == "--dry-run" ]]; then
        dry_run=1
    fi

    log "sync-plist: starting (dry_run=$dry_run)"

    if [[ ! -f "$AUTOMOUNT_PLIST" ]]; then
        log "sync-plist: WARN — plist not found at $AUTOMOUNT_PLIST, skipping"
        echo "WARNING: plist not found at $AUTOMOUNT_PLIST — nothing to update." >&2
        return 0
    fi

    if [[ ! -f "$FLEET_FILE" ]]; then
        log "sync-plist: WARN — fleet.json not found at $FLEET_FILE, skipping"
        echo "WARNING: fleet.json not found at $FLEET_FILE — cannot determine WatchPaths." >&2
        return 0
    fi

    DRY_RUN="$dry_run" python3 "$SCRIPTS_DIR/devdrive-syncplist.py"
    return $?
}


# ---------------------------------------------------------------------------
# stop-keepawake subcommand
# Kill any running keep-awake ping loops tracked via KEEPAWAKE_PID_FILE.
# ---------------------------------------------------------------------------
cmd_stop_keepawake() {
    if [[ ! -f "$KEEPAWAKE_PID_FILE" ]]; then
        echo "No keep-awake loop is running (pid file not found)."
        return 0
    fi
    local pid
    pid=$(cat "$KEEPAWAKE_PID_FILE" 2>/dev/null || echo "")
    if [[ -z "$pid" ]]; then
        rm -f "$KEEPAWAKE_PID_FILE"
        echo "No keep-awake loop is running (empty pid file)."
        return 0
    fi
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null && log "keep-awake: stopped loop pid $pid" && echo "Stopped keep-awake loop (pid $pid)."
    else
        log "keep-awake: pid $pid no longer running — removing stale pid file"
        echo "Keep-awake loop (pid $pid) was not running — removed stale pid file."
    fi
    rm -f "$KEEPAWAKE_PID_FILE"
}

# ---------------------------------------------------------------------------
# cmd_keepawake
# Start a background keep-awake ping loop for any external host volumes that
# have "keep_awake": true in fleet.json and are currently mounted.
#
# The loop issues `diskutil info <mountpoint>` every 60 seconds.  This is
# enough I/O to prevent macOS from spinning down an idle USB/Thunderbolt
# drive without stressing the drive unnecessarily.
#
# Only one loop process is kept alive at a time — if a stale PID file exists
# for a still-running process the loop is not duplicated.
# ---------------------------------------------------------------------------
cmd_keepawake() {
    [[ ! -f "$FLEET_FILE" ]] && return 0

    # Collect mount points of external hosts where keep_awake=true
    local keep_awake_mounts
    keep_awake_mounts=$(python3 - <<'KAEOF'
import json, os, sys
fleet_path = os.path.join(os.environ['HOME'], 'DevDrive', 'fleet.json')
try:
    with open(fleet_path) as f:
        fleet = json.load(f)
except Exception:
    sys.exit(0)
for host in fleet.get('external_hosts', []):
    if host.get('keep_awake') and os.path.isdir(host.get('mount', '')):
        print(host['mount'])
KAEOF
)

    if [[ -z "$keep_awake_mounts" ]]; then
        # No keep_awake hosts are currently mounted — ensure no stale loop
        if [[ -f "$KEEPAWAKE_PID_FILE" ]]; then
            local stale_pid
            stale_pid=$(cat "$KEEPAWAKE_PID_FILE" 2>/dev/null || echo "")
            if [[ -n "$stale_pid" ]] && ! kill -0 "$stale_pid" 2>/dev/null; then
                rm -f "$KEEPAWAKE_PID_FILE"
                log "keep-awake: removed stale pid file ($stale_pid)"
            fi
        fi
        return 0
    fi

    # Check if a loop is already alive
    if [[ -f "$KEEPAWAKE_PID_FILE" ]]; then
        local existing_pid
        existing_pid=$(cat "$KEEPAWAKE_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            log "keep-awake: loop already running (pid $existing_pid) — skipping"
            return 0
        fi
        rm -f "$KEEPAWAKE_PID_FILE"
    fi

    # Launch the ping loop as a detached background subshell
    (
        log "keep-awake: starting loop for: $(echo "$keep_awake_mounts" | tr '\n' ' ')"
        while true; do
            # Re-read fleet.json each iteration so removed keep_awake entries
            # cause the loop to exit cleanly without needing a restart.
            local current_mounts
            current_mounts=$(python3 - <<'INNEREOF'
import json, os, sys
fleet_path = os.path.join(os.environ['HOME'], 'DevDrive', 'fleet.json')
try:
    with open(fleet_path) as f:
        fleet = json.load(f)
except Exception:
    sys.exit(0)
for host in fleet.get('external_hosts', []):
    if host.get('keep_awake') and os.path.isdir(host.get('mount', '')):
        print(host['mount'])
INNEREOF
)
            if [[ -z "$current_mounts" ]]; then
                log "keep-awake: no keep_awake hosts mounted — loop exiting"
                rm -f "$KEEPAWAKE_PID_FILE"
                exit 0
            fi
            while IFS= read -r mount_path; do
                if [[ -d "$mount_path" ]]; then
                    if diskutil info "$mount_path" > /dev/null 2>&1; then
                        log "keep-awake: pinged $mount_path"
                    else
                        log "keep-awake: ping failed for $mount_path (unmounted?)"
                    fi
                fi
            done <<< "$current_mounts"
            sleep 60
        done
    ) &
    local loop_pid=$!
    disown "$loop_pid"
    echo "$loop_pid" > "$KEEPAWAKE_PID_FILE"
    log "keep-awake: loop started (pid $loop_pid)"
}

# ---------------------------------------------------------------------------
# Argument dispatch
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "sync-plist" ]]; then
    cmd_sync_plist "${2:-}"
    exit $?
fi

if [[ "${1:-}" == "stop-keepawake" ]]; then
    cmd_stop_keepawake
    exit $?
fi

[[ ! -f "$FLEET_FILE" ]] && log "WARN: fleet.json not found — skipping" && exit 0

log "=== Automount triggered ==="

python3 << 'PYEOF'
import json, os, subprocess, sys, time

HOME = os.environ['HOME']
FLEET_FILE = os.path.join(HOME, 'DevDrive', 'fleet.json')
DEVDRIVE_HOME = os.path.join(HOME, 'DevDrive')
LOG_FILE = os.path.join(HOME, '.config', 'lfg', 'automount.log')

def log(msg):
    import datetime
    ts = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(f"{ts} [automount] {msg}\n")
    except Exception:
        pass

def notify_apm(event, data):
    import urllib.request
    try:
        payload = json.dumps({"source": "lfg-devdrive", "event": event, "data": data}).encode()
        req = urllib.request.Request(
            "http://localhost:3032/api/notify", data=payload,
            headers={"Content-Type": "application/json"}, method="POST"
        )
        urllib.request.urlopen(req, timeout=2)
    except Exception:
        pass

def is_mounted(path):
    return os.path.isdir(path) and path != '/'

def verify_external_host(host_entry):
    """Return True only if the volume at host_entry['mount'] matches the
    recorded UUID (if present).  Falls back to path-existence check when
    no UUID is recorded, so older fleet.json entries still work."""
    mount = host_entry.get('mount', '')
    expected_uuid = host_entry.get('volume_uuid', '')
    if not is_mounted(mount):
        return False
    if not expected_uuid:
        return True  # no UUID to verify — trust path presence
    try:
        result = subprocess.run(
            ['diskutil', 'info', '-plist', mount],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            return True  # diskutil failed — fall back to path check
        import plistlib
        info = plistlib.loads(result.stdout.encode())
        actual_uuid = info.get('VolumeUUID', '')
        if actual_uuid and actual_uuid.upper() != expected_uuid.upper():
            log(f"UUID MISMATCH for {mount}: expected {expected_uuid}, got {actual_uuid} — skipping")
            return False
        return True
    except Exception as e:
        log(f"verify_external_host error for {mount}: {e} — falling back to path check")
        return True

def attach_image(image_path, drive_id):
    """hdiutil attach — returns True if succeeded or already attached."""
    result = subprocess.run(
        ['hdiutil', 'attach', image_path, '-noverify', '-noautofsck'],
        capture_output=True, text=True, timeout=60
    )
    if result.returncode == 0:
        log(f"[{drive_id}] attached: {image_path}")
        return True
    stderr = result.stderr.strip()
    if 'already attached' in stderr.lower() or 'Resource busy' in stderr:
        log(f"[{drive_id}] already attached: {image_path}")
        return True
    log(f"[{drive_id}] attach FAILED: {stderr[:300]}")
    return False

def ensure_symlink(link_path, target):
    """Create or update a symlink; skip if already correct."""
    link_path = os.path.expanduser(link_path)
    if os.path.islink(link_path):
        if os.readlink(link_path) == target:
            return
        os.unlink(link_path)
    elif os.path.exists(link_path):
        return  # real path exists — don't clobber
    os.makedirs(os.path.dirname(link_path), exist_ok=True)
    os.symlink(target, link_path)
    log(f"symlink: {link_path} -> {target}")

try:
    with open(FLEET_FILE) as f:
        fleet = json.load(f)
except Exception as e:
    log(f"ERROR reading fleet.json: {e}")
    sys.exit(1)

# Build external host map: {name -> host_entry dict}
external_host_map = {h['name']: h for h in fleet.get('external_hosts', [])}
# Backward-compat alias: plain mount path lookup
external_hosts = {name: h['mount'] for name, h in external_host_map.items()}

mounted_count = 0
already_count = 0
failed_count = 0

# When triggered by WatchPaths (a volume just appeared), the APFS container
# may not be fully registered with diskutil yet.  Wait up to 8 seconds for
# each external host to become queryable, checking every 2 seconds.
# This avoids the "not verified (unmounted or UUID mismatch)" false-negative
# that occurs when the agent fires too quickly after wake.
SETTLE_TIMEOUT = 8   # seconds total to wait per host
SETTLE_POLL    = 2   # seconds between checks

for host_entry in fleet.get('external_hosts', []):
    mount = host_entry.get('mount', '')
    if not mount:
        continue
    if is_mounted(mount):
        # Host is up — poll until diskutil can read it or timeout expires
        waited = 0
        while waited < SETTLE_TIMEOUT:
            result = subprocess.run(['diskutil', 'info', '-plist', mount],
                                    capture_output=True, text=True, timeout=10)
            if result.returncode == 0 and result.stdout.strip():
                log(f"settle: {mount} ready after {waited}s")
                break
            time.sleep(SETTLE_POLL)
            waited += SETTLE_POLL
        else:
            log(f"settle: {mount} still not queryable after {SETTLE_TIMEOUT}s — proceeding anyway")

for drive in fleet.get('drives', []):
    drive_id = drive.get('id', '?')
    image_raw = drive.get('image', '')
    mount_point = drive.get('mount', '')
    mount_alias = drive.get('mount_alias', '')
    host_name = drive.get('host', 'internal')
    reconnect_policy = drive.get('reconnect_policy', 'auto')

    if reconnect_policy == 'manual':
        log(f"[{drive_id}] reconnect_policy=manual — skipping")
        continue

    image = os.path.expanduser(image_raw)

    # Check if volume is already accessible
    active_mount = mount_point if is_mounted(mount_point) else (mount_alias if mount_alias and is_mounted(mount_alias) else '')
    if active_mount:
        log(f"[{drive_id}] already mounted at {active_mount}")
        already_count += 1
    else:
        # For external host drives, verify the host is mounted and UUID matches
        if host_name != 'internal' and host_name in external_host_map:
            host_entry = external_host_map[host_name]
            if not verify_external_host(host_entry):
                log(f"[{drive_id}] host {host_name} not verified (unmounted or UUID mismatch) — skipping")
                continue

        if not image:
            log(f"[{drive_id}] no image path — skipping")
            continue

        if not os.path.exists(image):
            log(f"[{drive_id}] image not found: {image}")
            failed_count += 1
            continue

        if attach_image(image, drive_id):
            # Give macOS a moment to register the APFS volume
            time.sleep(1)
            active_mount = mount_point if is_mounted(mount_point) else (mount_alias if mount_alias and is_mounted(mount_alias) else '')
            if active_mount:
                mounted_count += 1
                notify_apm("volume_automount", {"volume_id": drive_id, "mount": active_mount})
            else:
                log(f"[{drive_id}] attached but volume not at expected mount {mount_point}")
                mounted_count += 1  # still count as success
        else:
            failed_count += 1
            continue

    # Rebuild ~/DevDrive symlink for this volume
    if active_mount:
        link = os.path.join(DEVDRIVE_HOME, drive_id)
        if not os.path.islink(link):
            try:
                os.symlink(active_mount, link)
                log(f"[{drive_id}] symlink: {link} -> {active_mount}")
            except Exception as e:
                log(f"[{drive_id}] symlink error: {e}")

        # Restore per-drive symlinks (e.g. CoreSimulator/Devices)
        for sl in drive.get('symlinks', []):
            sep = ' -> ' if ' -> ' in sl else ' → '
            if sep not in sl:
                continue
            sys_path = sl.split(sep)[0].strip()
            vol_target = sl.split(sep)[1].strip()
            ensure_symlink(sys_path, vol_target)

log(f"=== Automount done: mounted={mounted_count} already={already_count} failed={failed_count} ===")
PYEOF

# Keep WatchPaths in sync with fleet.json after every successful automount run.
cmd_sync_plist

# Start keep-awake loops for any mounted external hosts that request it.
cmd_keepawake

#!/usr/bin/env bash
# devdrive-automount.sh — Fleet-aware DevDrive automount helper.
# Triggered by io.lfg.devdrive-automount LaunchAgent on login and when
# any external host volume mounts (via WatchPaths in the plist).
#
# Subcommands:
#   (none)         Normal automount run — mounts all fleet volumes.
#   sync-plist     Re-write WatchPaths in the automount LaunchAgent plist
#                  from fleet.json external_hosts, then reload the agent.
set -uo pipefail

LOG_DIR="$HOME/.config/lfg"
LOG="$LOG_DIR/automount.log"
FLEET_FILE="$HOME/DevDrive/fleet.json"
DEVDRIVE_HOME="$HOME/DevDrive"
AUTOMOUNT_PLIST="$HOME/Library/LaunchAgents/io.lfg.devdrive-automount.plist"

mkdir -p "$LOG_DIR" "$DEVDRIVE_HOME" 2>/dev/null

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [automount] $*" >> "$LOG"; }

# ---------------------------------------------------------------------------
# sync-plist subcommand
# Re-writes the WatchPaths array in the automount LaunchAgent plist so it
# contains exactly the external_hosts[].mount paths from fleet.json, then
# reloads the LaunchAgent so the new paths take effect immediately.
# ---------------------------------------------------------------------------
cmd_sync_plist() {
    log "sync-plist: starting"

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

    python3 << 'SYNCEOF'
import json, os, plistlib, subprocess, sys

HOME        = os.environ['HOME']
FLEET_FILE  = os.path.join(HOME, 'DevDrive', 'fleet.json')
PLIST_PATH  = os.path.join(HOME, 'Library', 'LaunchAgents', 'io.lfg.devdrive-automount.plist')
LOG_FILE    = os.path.join(HOME, '.config', 'lfg', 'automount.log')

def log(msg):
    import datetime
    ts = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(f"{ts} [automount] {msg}\n")
    except Exception:
        pass

# Read fleet.json and extract external host mount paths
try:
    with open(FLEET_FILE) as f:
        fleet = json.load(f)
except Exception as e:
    log(f"sync-plist: ERROR reading fleet.json: {e}")
    print(f"ERROR: could not read fleet.json: {e}", file=sys.stderr)
    sys.exit(1)

watch_paths = [h['mount'] for h in fleet.get('external_hosts', []) if h.get('mount')]
if not watch_paths:
    log("sync-plist: WARN — no external_hosts with mount paths found in fleet.json")
    print("WARNING: no external_hosts mount paths found — WatchPaths not changed.")
    sys.exit(0)

# Read existing plist (XML format)
try:
    with open(PLIST_PATH, 'rb') as f:
        plist_data = plistlib.load(f)
except Exception as e:
    log(f"sync-plist: ERROR reading plist: {e}")
    print(f"ERROR: could not read plist at {PLIST_PATH}: {e}", file=sys.stderr)
    sys.exit(1)

old_watch = list(plist_data.get('WatchPaths', []))

# Update WatchPaths in memory
plist_data['WatchPaths'] = watch_paths

# Write back as XML plist
try:
    with open(PLIST_PATH, 'wb') as f:
        plistlib.dump(plist_data, f, fmt=plistlib.FMT_XML, sort_keys=False)
except Exception as e:
    log(f"sync-plist: ERROR writing plist: {e}")
    print(f"ERROR: could not write plist: {e}", file=sys.stderr)
    sys.exit(1)

log(f"sync-plist: WatchPaths updated: {old_watch} -> {watch_paths}")
print(f"sync-plist: WatchPaths updated")
print(f"  old: {old_watch}")
print(f"  new: {watch_paths}")

# Reload the LaunchAgent so the new WatchPaths take effect
unload = subprocess.run(['launchctl', 'unload', PLIST_PATH], capture_output=True, text=True)
if unload.returncode != 0 and 'Could not find specified service' not in unload.stderr:
    log(f"sync-plist: WARN launchctl unload returned {unload.returncode}: {unload.stderr.strip()}")

load = subprocess.run(['launchctl', 'load', PLIST_PATH], capture_output=True, text=True)
if load.returncode == 0:
    log("sync-plist: LaunchAgent reloaded successfully")
    print("sync-plist: LaunchAgent reloaded successfully")
else:
    log(f"sync-plist: WARN launchctl load returned {load.returncode}: {load.stderr.strip()}")
    print(f"WARNING: launchctl load exited {load.returncode}: {load.stderr.strip()}", file=sys.stderr)

SYNCEOF
    return $?
}

# ---------------------------------------------------------------------------
# Argument dispatch
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "sync-plist" ]]; then
    cmd_sync_plist
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

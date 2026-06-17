#!/usr/bin/env bash
# devdrive-reconcile.sh — Periodic reconcile loop for DevDrive volumes.
# Called by io.lfg.devdrive-reconcile.plist (LaunchAgent, every 60s).
#
# Behaviour:
#   1. Read fleet.json
#   2. For each drive, check if mounted
#   3. If offline: ensure fallback dir exists; redirect broken symlinks to fallback
#   4. If offline but was previously online: attempt reconnect via 'lfg devdrive reconnect'
#   5. Log all events to ~/.config/lfg/devdrive-reconcile.log

set -uo pipefail

LFG_BIN="/Users/jeremiah/tools/@yj/lfg/lfg"
FLEET_FILE="$HOME/DevDrive/fleet.json"
DEVDRIVE_HOME="$HOME/DevDrive"
LOG_FILE="$HOME/.config/lfg/devdrive-reconcile.log"
STATE_FILE="$HOME/.config/lfg/devdrive-reconcile-state.json"

mkdir -p "$(dirname "$LOG_FILE")" "$DEVDRIVE_HOME"

ts() { date "+%Y-%m-%dT%H:%M:%S"; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }

[[ ! -f "$FLEET_FILE" ]] && log "WARN: fleet.json not found at $FLEET_FILE — skipping" && exit 0

# Load previous state (which volumes were online last poll)
prev_state="{}"
[[ -f "$STATE_FILE" ]] && prev_state=$(cat "$STATE_FILE" 2>/dev/null || echo "{}")

new_state="{}"

python3 << RECONCILE_PY
import json, os, subprocess, sys, datetime, urllib.request

fleet_file = "$FLEET_FILE"
devdrive_home = "$DEVDRIVE_HOME"
log_file = "$LOG_FILE"
state_file = "$STATE_FILE"
lfg_bin = "$LFG_BIN"

def notify_apm(event, data):
    """Fire-and-forget APM notification (timeout 2s, fail silently)."""
    try:
        payload = json.dumps({"source": "lfg-devdrive", "event": event, "data": data}).encode()
        req = urllib.request.Request(
            "http://localhost:3032/api/notify",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=2)
    except Exception:
        pass

def log(msg):
    ts = datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S')
    line = f"[{ts}] {msg}"
    try:
        with open(log_file, 'a') as f:
            f.write(line + '\n')
    except Exception:
        pass

try:
    with open(fleet_file) as f:
        fleet = json.load(f)
except Exception as e:
    log(f"ERROR: Could not read fleet.json: {e}")
    sys.exit(1)

try:
    with open(state_file) as f:
        prev_state = json.load(f)
except Exception:
    prev_state = {}

new_state = {}

for drive in fleet.get('drives', []):
    drive_id = drive.get('id', '')
    mount = drive.get('mount', '')
    mount_alias = drive.get('mount_alias', '')
    image = os.path.expanduser(drive.get('image', ''))

    mounted = os.path.isdir(mount) or (mount_alias and os.path.isdir(mount_alias))
    was_mounted = prev_state.get(drive_id, {}).get('mounted', True)  # assume mounted if unknown

    new_state[drive_id] = {'mounted': mounted, 'mount': mount}

    if mounted:
        if not was_mounted:
            log(f"[{drive_id}] Volume came ONLINE at {mount} — restoring symlinks")
            notify_apm("volume_reconnect", {"volume_id": drive_id, "timestamp": datetime.datetime.now().isoformat()})
            try:
                result = subprocess.run(
                    [lfg_bin, 'devdrive', 'reconnect', drive_id],
                    capture_output=True, text=True, timeout=120,
                    env={**os.environ, 'LFG_NO_VIEWER': '1'}
                )
                log(f"[{drive_id}] reconnect output: {result.stdout.strip()[:500]}")
                if result.returncode != 0:
                    log(f"[{drive_id}] reconnect stderr: {result.stderr.strip()[:200]}")
            except Exception as e:
                log(f"[{drive_id}] reconnect error: {e}")
        # Volume online and was online — nothing to do
        continue

    # Volume is offline
    if was_mounted:
        log(f"[{drive_id}] Volume went OFFLINE (was at {mount}) — creating fallback")
        fallback_notify = os.path.join(devdrive_home, f"{drive_id}-fallback")
        notify_apm("volume_disconnect", {"volume_id": drive_id, "timestamp": datetime.datetime.now().isoformat(), "fallback_path": fallback_notify})

    # Ensure fallback dir for DevDrive-internal symlinks only.
    # Home-dir offloads (symlinks outside ~/DevDrive/) are left as dangling when offline:
    # a broken symlink causes a tool-level error, which is safer than redirecting to an
    # empty internal dir that silently fills the boot volume while the drive is temporarily offline.
    fallback = os.path.join(devdrive_home, f"{drive_id}-fallback")

    for sl in drive.get('symlinks', []):
        sep = ' -> ' if ' -> ' in sl else ' \u2192 '
        if sep not in sl:
            continue
        sys_path = os.path.expanduser(sl.split(sep)[0].strip())
        vol_subpath = sl.split(sep)[1].strip()

        # Skip fallback redirect for home-dir offloads (source is not inside ~/DevDrive/)
        is_devdrive_internal = sys_path.startswith(devdrive_home + os.sep) or sys_path == devdrive_home
        if not is_devdrive_internal:
            if os.path.islink(sys_path) and not os.path.exists(sys_path):
                log(f"[{drive_id}] HOME OFFLOAD dangling (offline, will restore on reconnect): {sys_path}")
            continue

        if vol_subpath.startswith(mount + '/'):
            subdir = vol_subpath[len(mount)+1:]
        else:
            subdir = os.path.basename(vol_subpath)
        fallback_target = os.path.join(fallback, subdir)
        os.makedirs(fallback, exist_ok=True)
        os.makedirs(fallback_target, exist_ok=True)

        if os.path.islink(sys_path) and not os.path.exists(sys_path):
            # Broken DevDrive-internal symlink — redirect to fallback
            try:
                current = os.readlink(sys_path)
                if current != fallback_target:
                    os.unlink(sys_path)
                    os.symlink(fallback_target, sys_path)
                    log(f"[{drive_id}] FALLBACK: {sys_path} -> {fallback_target}")
            except Exception as e:
                log(f"[{drive_id}] ERROR redirecting {sys_path}: {e}")
        elif not os.path.exists(sys_path):
            # Missing DevDrive-internal entry — create pointing to fallback
            try:
                parent = os.path.dirname(sys_path)
                os.makedirs(parent, exist_ok=True)
                os.symlink(fallback_target, sys_path)
                log(f"[{drive_id}] FALLBACK (new): {sys_path} -> {fallback_target}")
            except Exception as e:
                log(f"[{drive_id}] ERROR creating fallback symlink: {e}")

    # Attempt to reconnect (attach image)
    if image and os.path.exists(image):
        log(f"[{drive_id}] Attempting auto-reconnect...")
        try:
            result = subprocess.run(
                [lfg_bin, 'devdrive', 'reconnect', drive_id],
                capture_output=True, text=True, timeout=120,
                env={**os.environ, 'LFG_NO_VIEWER': '1'}
            )
            if result.returncode == 0:
                log(f"[{drive_id}] auto-reconnect: {result.stdout.strip()[:300]}")
                # Check if actually mounted now
                if os.path.isdir(mount) or (mount_alias and os.path.isdir(mount_alias)):
                    new_state[drive_id]['mounted'] = True
            else:
                log(f"[{drive_id}] auto-reconnect failed: {result.stderr.strip()[:200]}")
        except Exception as e:
            log(f"[{drive_id}] auto-reconnect error: {e}")
    else:
        if image:
            # Image not directly accessible — may be on an external host that just appeared.
            # Check fleet.json external_hosts: if the host volume is now mounted, run the
            # automount helper which knows how to attach sparseimages from external hosts.
            host_name = drive.get('host', 'internal')
            external_host_map = {h['name']: h for h in fleet.get('external_hosts', [])}
            if host_name != 'internal' and host_name in external_host_map:
                host_mount = external_host_map[host_name].get('mount', '')
                if host_mount and os.path.isdir(host_mount):
                    log(f"[{drive_id}] Image at {image} not yet accessible but host {host_name} is mounted — triggering automount helper")
                    automount_script = os.path.join(os.path.dirname(lfg_bin), 'scripts', 'devdrive-automount.sh')
                    try:
                        subprocess.run(
                            ['/bin/bash', automount_script],
                            capture_output=True, text=True, timeout=90,
                            env={**os.environ, 'LFG_NO_VIEWER': '1'}
                        )
                        # After automount, recheck
                        if os.path.isdir(mount) or (mount_alias and os.path.isdir(mount_alias)):
                            new_state[drive_id]['mounted'] = True
                            log(f"[{drive_id}] automount helper succeeded — volume now at {mount}")
                    except Exception as e:
                        log(f"[{drive_id}] automount helper error: {e}")
                else:
                    log(f"[{drive_id}] Image not accessible at {image} — host {host_name} not mounted, will retry next poll")
            else:
                log(f"[{drive_id}] Image not accessible at {image} — cannot auto-reconnect")

# Persist new state
try:
    with open(state_file, 'w') as f:
        json.dump(new_state, f, indent=2)
except Exception as e:
    log(f"ERROR: Could not write state file: {e}")
RECONCILE_PY

# After reconcile: run capacity check every 5th run (roughly every 5 minutes)
CAPACITY_CHECK_SCRIPT="$(dirname "$0")/devdrive-capacity-check.sh"
CAPACITY_COUNTER_FILE="$HOME/.config/lfg/.capacity-check-counter"
if [[ -f "$CAPACITY_CHECK_SCRIPT" ]]; then
  counter=0
  [[ -f "$CAPACITY_COUNTER_FILE" ]] && counter=$(cat "$CAPACITY_COUNTER_FILE" 2>/dev/null || echo 0)
  counter=$(( (counter + 1) % 5 ))
  echo "$counter" > "$CAPACITY_COUNTER_FILE"
  if [[ "$counter" -eq 0 ]]; then
    "$CAPACITY_CHECK_SCRIPT" >> "$LOG_FILE" 2>&1 || true
  fi
fi


#!/usr/bin/env bash
# devdrive-capacity-check.sh — Check devdrive volumes for capacity and trigger spillover
# when a volume exceeds SPILL_THRESHOLD (default 85%).
#
# Spillover strategy:
#   - When volume A is >85% full, eligible new forest entries are placed on a
#     sibling volume that has >15% free (the "overflow" volume).
#   - For sparseimage volumes: attempts hdiutil resize +5g if on a host with space.
#   - Reports volumes at risk and suggests rebalance actions.
#   - Does NOT move existing symlinks (too disruptive); flags them for manual review.
#
# Called by: lfg devdrive status, devdrive-reconcile.sh (when checking health)
# Also callable standalone: ~/tools/@yj/lfg/scripts/devdrive-capacity-check.sh [--rebalance]

set -uo pipefail

FLEET_FILE="$HOME/DevDrive/fleet.json"
FOREST_FILE="$HOME/.config/lfg/devdrive_forest.json"
LOG_FILE="$HOME/.config/lfg/devdrive-capacity.log"
SPILL_THRESHOLD=85   # % used — trigger spillover assignment when exceeded
CRITICAL_THRESHOLD=95 # % used — trigger resize attempt

mkdir -p "$(dirname "$LOG_FILE")"

ts() { date "+%Y-%m-%dT%H:%M:%S"; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }

REBALANCE=false
for arg in "$@"; do
  case "$arg" in
    --rebalance) REBALANCE=true ;;
  esac
done

log "=== devdrive-capacity-check start (rebalance=$REBALANCE) ==="

python3 << CAPCHECK_PY
import json, os, subprocess, sys, datetime, urllib.request

fleet_file = os.path.expanduser("$FLEET_FILE")
forest_file = os.path.expanduser("$FOREST_FILE")
log_file = os.path.expanduser("$LOG_FILE")
spill_threshold = $SPILL_THRESHOLD
critical_threshold = $CRITICAL_THRESHOLD
rebalance = "$REBALANCE" == "true"

def log(msg):
    ts = datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S')
    with open(log_file, 'a') as f:
        f.write(f"[{ts}] {msg}\n")
    print(msg)

def notify_apm(title, message, level="warn"):
    try:
        payload = json.dumps({"type": "lfg-devdrive", "title": title, "message": message, "level": level}).encode()
        req = urllib.request.Request(
            "http://localhost:3032/api/notifications/add",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=2)
    except Exception:
        pass

def get_volume_usage(mount_point):
    """Returns (used_pct, avail_bytes, total_bytes) or None if not mounted."""
    if not os.path.isdir(mount_point):
        return None
    try:
        result = subprocess.run(
            ["df", "-k", mount_point],
            capture_output=True, text=True, timeout=5
        )
        lines = result.stdout.strip().split("\n")
        if len(lines) < 2:
            return None
        parts = lines[1].split()
        if len(parts) < 5:
            return None
        total_kb = int(parts[1])
        used_kb = int(parts[2])
        avail_kb = int(parts[3])
        pct_str = parts[4].rstrip('%')
        used_pct = int(pct_str)
        return used_pct, avail_kb * 1024, total_kb * 1024
    except Exception:
        return None

def resize_sparseimage(image_path, add_gb=5):
    """Attempt to grow a sparseimage by add_gb gigabytes."""
    try:
        # Get current size
        info = subprocess.run(
            ["hdiutil", "resize", "-limits", image_path],
            capture_output=True, text=True, timeout=10
        )
        # Grow by add_gb
        result = subprocess.run(
            ["hdiutil", "resize", "-size", f"+{add_gb}g", image_path],
            capture_output=True, text=True, timeout=30
        )
        return result.returncode == 0, result.stdout + result.stderr
    except Exception as e:
        return False, str(e)

# ---- Load fleet ----
if not os.path.isfile(fleet_file):
    log(f"ERROR: fleet.json not found at {fleet_file}")
    sys.exit(1)

with open(fleet_file) as f:
    fleet = json.load(f)

# ---- Load forest ----
forest = {"symlinks": []}
if os.path.isfile(forest_file):
    with open(forest_file) as f:
        forest = json.load(f)

# ---- Assess each volume ----
volume_status = {}  # drive_id -> {mount, used_pct, avail_bytes, total_bytes, host, image}
at_risk = []
healthy = []

for drive in fleet.get("drives", []):
    drive_id = drive.get("id", "")
    mount = drive.get("mount", "")
    mount_alias = drive.get("mount_alias", "")
    image = os.path.expanduser(drive.get("image", ""))
    host = drive.get("host", "internal")
    host_path = os.path.expanduser(drive.get("host_path", "~/DevDrive"))
    size = drive.get("size", "unknown")

    # Find the actual mount point
    actual_mount = None
    for mp in [mount, mount_alias]:
        if mp and os.path.isdir(mp):
            actual_mount = mp
            break

    if actual_mount is None:
        log(f"  [{drive_id}] NOT MOUNTED — skipping capacity check")
        volume_status[drive_id] = {"mounted": False, "mount": mount, "host": host, "image": image}
        continue

    usage = get_volume_usage(actual_mount)
    if usage is None:
        log(f"  [{drive_id}] Could not get usage for {actual_mount}")
        continue

    used_pct, avail_bytes, total_bytes = usage
    avail_gb = avail_bytes / (1024**3)
    total_gb = total_bytes / (1024**3)

    volume_status[drive_id] = {
        "mounted": True,
        "mount": actual_mount,
        "host": host,
        "image": image,
        "host_path": host_path,
        "used_pct": used_pct,
        "avail_bytes": avail_bytes,
        "total_bytes": total_bytes,
        "size_declared": size,
    }

    status_icon = "OK" if used_pct < spill_threshold else ("WARN" if used_pct < critical_threshold else "CRIT")
    log(f"  [{drive_id}] {status_icon} {actual_mount}: {used_pct}% used, {avail_gb:.1f}GB free / {total_gb:.1f}GB total")

    if used_pct >= spill_threshold:
        at_risk.append(drive_id)
    else:
        healthy.append(drive_id)

# ---- Report at-risk volumes and suggest/act on spillover ----
if not at_risk:
    log("All mounted volumes within capacity. No spillover needed.")
else:
    log(f"\nAt-risk volumes (>{spill_threshold}% full): {at_risk}")

    # Identify overflow candidates: mounted volumes on different hosts with headroom
    for risk_id in at_risk:
        risk = volume_status.get(risk_id, {})
        if not risk.get("mounted"):
            continue

        used_pct = risk.get("used_pct", 100)
        image_path = risk.get("image", "")
        host = risk.get("host", "internal")
        mount = risk.get("mount", "")

        # Strategy 1: Try to resize the sparseimage if it's accessible
        if used_pct >= critical_threshold and image_path and os.path.isfile(image_path):
            # Check host volume has space to expand
            host_path = risk.get("host_path", "")
            host_usage = get_volume_usage(host_path) if host_path and os.path.isdir(host_path) else None
            if host_usage and host_usage[1] > (5 * 1024**3):  # >5GB free on host
                log(f"  [{risk_id}] CRITICAL — attempting sparseimage resize +5g on {image_path}")
                if rebalance:
                    ok, msg = resize_sparseimage(image_path, add_gb=5)
                    if ok:
                        log(f"  [{risk_id}] Resize OK: {msg[:200]}")
                        notify_apm(
                            f"DevDrive {risk_id} Expanded",
                            f"Sparseimage at {image_path} grown +5g. Was {used_pct}% full.",
                            "info"
                        )
                    else:
                        log(f"  [{risk_id}] Resize FAILED: {msg[:200]}")
                        notify_apm(
                            f"DevDrive {risk_id} Resize Failed",
                            f"Could not grow {image_path}. Manual intervention needed. {msg[:200]}",
                            "error"
                        )
                else:
                    log(f"  [{risk_id}] DRY RUN: would resize {image_path} +5g (run with --rebalance to apply)")
            else:
                log(f"  [{risk_id}] Host {host_path} has insufficient space for resize")

        # Strategy 2: Identify overflow volume for new forest entries
        overflow_candidates = []
        for cand_id, cand in volume_status.items():
            if not cand.get("mounted"):
                continue
            if cand_id == risk_id:
                continue
            cand_pct = cand.get("used_pct", 100)
            cand_avail = cand.get("avail_bytes", 0)
            if cand_pct < spill_threshold and cand_avail > (2 * 1024**3):  # >2GB free
                overflow_candidates.append((cand_id, cand_pct, cand.get("mount")))

        overflow_candidates.sort(key=lambda x: x[1])  # least-used first

        if overflow_candidates:
            preferred = overflow_candidates[0]
            log(f"  [{risk_id}] Overflow recommendation: new forest entries should go to [{preferred[0]}] ({preferred[1]}% used, mount={preferred[2]})")
        else:
            log(f"  [{risk_id}] WARNING: No overflow candidate available. All volumes at risk or unmounted.")
            notify_apm(
                f"DevDrive Fleet Capacity Warning",
                f"Volume {risk_id} is {used_pct}% full and no overflow volume is available. Check fleet.",
                "error"
            )

        # Strategy 3: Check forest entries pointing to this volume and flag large ones
        if forest.get("symlinks"):
            risky_entries = [
                s for s in forest["symlinks"]
                if s.get("volume_label", "").replace("DDRV-", "").replace("-", "").upper() in risk_id.upper()
                   or s.get("volume", "").replace("-", "").upper() in risk_id.replace("-", "").upper()
            ]
            if risky_entries:
                log(f"  [{risk_id}] Forest entries on this volume ({len(risky_entries)}):")
                for entry in risky_entries:
                    size_mb = entry.get("size_mb", 0)
                    log(f"    - {entry.get('id', '?')} ({size_mb}MB): {entry.get('system_path','?')} -> {entry.get('volume_path','?')}")
                if overflow_candidates and rebalance:
                    log(f"  [{risk_id}] NOTE: Symlink migration requires manual steps. See docs/devdrive-spillover.md")

# ---- Summary ----
log(f"\nCapacity check complete. Healthy: {len(healthy)}, At-risk: {len(at_risk)}")

# Write a machine-readable summary to state.json
state_file = os.path.expanduser("~/.config/lfg/state.json")
state = {}
if os.path.isfile(state_file):
    try:
        with open(state_file) as f:
            state = json.load(f)
    except Exception:
        pass

state.setdefault("devdrive", {})["capacity_check"] = {
    "timestamp": datetime.datetime.now().isoformat(),
    "at_risk": at_risk,
    "healthy": healthy,
    "volumes": {
        k: {"used_pct": v.get("used_pct"), "mounted": v.get("mounted"), "mount": v.get("mount")}
        for k, v in volume_status.items()
    }
}
try:
    with open(state_file, 'w') as f:
        json.dump(state, f, indent=2)
except Exception as e:
    log(f"WARNING: Could not update state.json: {e}")

CAPCHECK_PY

log "=== devdrive-capacity-check done ==="

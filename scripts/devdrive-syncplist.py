#!/usr/bin/env python3
"""devdrive-syncplist.py — Sync WatchPaths in the automount LaunchAgent plist
from fleet.json external_hosts.

Environment variables:
  DRY_RUN   Set to "1" to print the diff without writing or reloading.

WatchPath generation rules (macOS 13+ constraints):
  - Always include /Volumes (fires on any volume mount/unmount).
  - For each external_hosts entry: include /Volumes as parent (already covered).
  - For each drive entry that references an external host: if the drive records a
    host_volume field, add that path so the agent wakes when that specific
    sub-volume appears.  Fall back to the parent host mount if host_volume is
    absent.

macOS 13+ silently refuses WatchPaths on /Volumes/<name> subdirectories for
user LaunchAgents, so we only ever write /Volumes as the base.  Additional
host-specific paths are included for forward-compatibility and to expose the
computed set visibly in --dry-run output.
"""
import datetime
import json
import os
import plistlib
import subprocess
import sys

HOME = os.environ["HOME"]
FLEET_FILE = os.path.join(HOME, "DevDrive", "fleet.json")
PLIST_PATH = os.path.join(
    HOME, "Library", "LaunchAgents", "io.lfg.devdrive-automount.plist"
)
LOG_FILE = os.path.join(HOME, ".config", "lfg", "automount.log")
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"


def log(msg: str) -> None:
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        with open(LOG_FILE, "a") as fh:
            fh.write(f"{ts} [automount] {msg}\n")
    except Exception:
        pass


def build_watch_paths(fleet: dict) -> list:
    """Return the ordered, deduplicated WatchPaths list derived from fleet.json.

    Always starts with /Volumes.  For each external_hosts entry we include
    /Volumes (already present).  For each drive that names an external host we
    also include drive["host_volume"] when present, otherwise the host's mount
    path itself.  Duplicates are removed while preserving order.
    """
    seen: set = set()
    paths: list = []

    def add(p: str) -> None:
        if p and p not in seen:
            seen.add(p)
            paths.append(p)

    # Base: /Volumes always fires on any disk appearance
    add("/Volumes")

    # Build a lookup of external host name -> host entry
    host_map = {h["name"]: h for h in fleet.get("external_hosts", [])}

    # For each external host, include the mount path
    for host in fleet.get("external_hosts", []):
        mount = host.get("mount", "")
        if mount:
            add(mount)

    # For each drive that lives on an external host, include host_volume if set
    for drive in fleet.get("drives", []):
        host_name = drive.get("host", "internal")
        if host_name == "internal":
            continue
        host_volume = drive.get("host_volume", "")
        if host_volume:
            add(os.path.expanduser(host_volume))
        elif host_name in host_map:
            add(host_map[host_name].get("mount", ""))

    return paths


def main() -> int:
    # Read fleet.json
    try:
        with open(FLEET_FILE) as fh:
            fleet = json.load(fh)
    except Exception as exc:
        log(f"sync-plist: ERROR reading fleet.json: {exc}")
        print(f"ERROR: could not read fleet.json: {exc}", file=sys.stderr)
        return 1

    watch_paths = build_watch_paths(fleet)

    # Read existing plist
    try:
        with open(PLIST_PATH, "rb") as fh:
            plist_data = plistlib.load(fh)
    except Exception as exc:
        log(f"sync-plist: ERROR reading plist: {exc}")
        print(f"ERROR: could not read plist at {PLIST_PATH}: {exc}", file=sys.stderr)
        return 1

    old_watch = list(plist_data.get("WatchPaths", []))

    if DRY_RUN:
        print("sync-plist --dry-run: proposed WatchPaths change")
        print(f"  old: {old_watch}")
        print(f"  new: {watch_paths}")
        if old_watch == watch_paths:
            print("  (no change needed)")
        return 0

    # Update WatchPaths
    plist_data["WatchPaths"] = watch_paths

    try:
        with open(PLIST_PATH, "wb") as fh:
            plistlib.dump(plist_data, fh, fmt=plistlib.FMT_XML, sort_keys=False)
    except Exception as exc:
        log(f"sync-plist: ERROR writing plist: {exc}")
        print(f"ERROR: could not write plist: {exc}", file=sys.stderr)
        return 1

    log(f"sync-plist: WatchPaths updated: {old_watch} -> {watch_paths}")
    print("sync-plist: WatchPaths updated")
    print(f"  old: {old_watch}")
    print(f"  new: {watch_paths}")

    # Reload LaunchAgent using modern bootstrap/bootout API
    uid = os.getuid()
    domain = f"gui/{uid}"

    bootout = subprocess.run(
        ["launchctl", "bootout", domain, PLIST_PATH],
        capture_output=True,
        text=True,
    )
    if bootout.returncode != 0:
        stderr = bootout.stderr.strip()
        ignorable = ("No such process", "Could not find service", "36: Operation")
        if not any(x in stderr for x in ignorable):
            log(f"sync-plist: WARN launchctl bootout: {stderr}")

    bootstrap = subprocess.run(
        ["launchctl", "bootstrap", domain, PLIST_PATH],
        capture_output=True,
        text=True,
    )
    if bootstrap.returncode == 0:
        log("sync-plist: LaunchAgent bootstrapped successfully")
        print("sync-plist: LaunchAgent bootstrapped successfully")
    else:
        msg = f"launchctl bootstrap exited {bootstrap.returncode}: {bootstrap.stderr.strip()}"
        log(f"sync-plist: WARN {msg}")
        print(f"WARNING: {msg}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())

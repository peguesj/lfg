#!/usr/bin/env python3
"""Helper for lfg wtfs offload-audit — parses fleet.json and emits tagged lines.

Outputs:
  VOLUME <id> <mount> <size> <is_mounted 0|1> <free_kb>
  SYMLINK <src_expanded>|<target>      (pipe-delimited; paths may have spaces)
  CONSUMER <expanded_path>
"""
import json
import os
import subprocess
import sys


def main():
    fleet_file = sys.argv[1]
    home = sys.argv[2]

    try:
        with open(fleet_file) as fh:
            data = json.load(fh)
    except Exception as exc:
        sys.exit(f"fleet.json error: {exc}")

    for drive in data.get("drives", []):
        vid = drive.get("id", "?")
        mount = drive.get("mount", "")
        size = drive.get("size", "?")
        is_mounted = int(os.path.ismount(mount)) if mount else 0
        free_kb = 0
        if is_mounted:
            try:
                result = subprocess.run(
                    ["df", "-k", mount], capture_output=True, text=True
                )
                lines = result.stdout.strip().splitlines()
                if len(lines) >= 2:
                    free_kb = int(lines[1].split()[3])
            except Exception:
                pass
        print(f"VOLUME {vid} {mount} {size} {is_mounted} {free_kb}")

    for drive in data.get("drives", []):
        for sl in drive.get("symlinks", []):
            sep = " → " if " → " in sl else " -> "
            if sep not in sl:
                continue
            src, tgt = sl.split(sep, 1)
            src = src.replace("~", home).strip()
            tgt = tgt.strip()
            print(f"SYMLINK {src}|{tgt}")

    for consumer in data.get("known_internal_consumers", []):
        expanded = consumer.replace("~", home)
        print(f"CONSUMER {expanded}")


if __name__ == "__main__":
    main()

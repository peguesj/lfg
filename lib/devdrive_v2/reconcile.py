"""DevDrive v2 reconcile loop — dry-run drift classifier (US-002).

Examines all forest entries and volumes recorded in DevDriveState and emits
typed DriftEvent objects for every anomaly detected.  All filesystem and
subprocess calls are injected through thin callables so the entire module is
testable without real mounts.

Default log path: ~/.config/lfg/reconcile_log.jsonl
Default LaunchAgent interval: 300 s (see resources/io.lfg.devdrive-reconcile.plist)
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import time
from dataclasses import asdict, dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Optional

from devdrive_v2.state import ForestEntryKind, StateManager, VolumeHealth

logger = logging.getLogger(__name__)

DEFAULT_LOG_PATH = Path.home() / ".config" / "lfg" / "reconcile_log.jsonl"

# Pressure thresholds — all tunable at construction time.
DEFAULT_BAND_BLOAT_THRESHOLD = 50_000
DEFAULT_SWAP_THRESHOLD_BYTES = 4 * 1024 ** 3          # 4 GiB
DEFAULT_SNAPSHOT_THRESHOLD_BYTES = 10 * 1024 ** 3     # 10 GiB


# ---------------------------------------------------------------------------
# Public enumerations
# ---------------------------------------------------------------------------


class DriftCategory(str, Enum):
    """Taxonomy of conditions that classify as drift."""

    MISSING_LINK = "missing_link"
    """Symlink expected at system_path but path does not exist at all."""

    STALE_TARGET = "stale_target"
    """Symlink exists at system_path but its target path is gone."""

    REAL_DIR_DRIFT = "real_dir_drift"
    """Expected a symlink but found a real (non-symlink) directory."""

    UNMOUNTED_VOL = "unmounted_vol"
    """Volume is registered in state but its mount_point is not mounted."""

    OVERSIZED = "oversized"
    """Volume used_bytes exceeds its configured quota_bytes."""

    BAND_BLOAT = "band_bloat"
    """Sparse-image band file count exceeds the configured threshold."""

    SNAPSHOT_LOCKED = "snapshot_locked"
    """APFS local snapshots on / are consuming more than the threshold."""

    SWAP_PRESSURE = "swap_pressure"
    """System swap usage exceeds the configured threshold."""


# ---------------------------------------------------------------------------
# DriftEvent
# ---------------------------------------------------------------------------


@dataclass
class DriftEvent:
    """A single detected drift condition."""

    category: DriftCategory
    source: str          # path, volume name, or subsystem identifier
    detail: str          # human-readable description
    severity: str        # "info" | "warning" | "critical"
    ts: float = field(default_factory=time.time)

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["category"] = self.category.value
        return d


# ---------------------------------------------------------------------------
# Injectable filesystem / subprocess helpers (defaults use the real OS)
# ---------------------------------------------------------------------------

# Type aliases for the injectable callables.
_IsLinkFn = Callable[[str], bool]
_ExistsFn = Callable[[str], bool]
_IsDirFn = Callable[[str], bool]
_ReadlinkFn = Callable[[str], str]
_RunFn = Callable[..., subprocess.CompletedProcess]  # type: ignore[type-arg]


def _default_run(*args: Any, **kwargs: Any) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
    return subprocess.run(*args, **kwargs)


# ---------------------------------------------------------------------------
# ReconcileLoop
# ---------------------------------------------------------------------------


class ReconcileLoop:
    """Classify drift across the entire DevDrive forest and volume inventory.

    Args:
        state_mgr: A loaded (or lazily-loading) StateManager instance.
        log_path: JSONL file for appending per-event records.  Parent
            directories are created automatically.
        band_bloat_threshold: Band file count above which BAND_BLOAT fires.
        swap_threshold_bytes: Swap bytes above which SWAP_PRESSURE fires.
        snapshot_threshold_bytes: Snapshot bytes above which
            SNAPSHOT_LOCKED fires.
        _islink: Injectable replacement for os.path.islink (testing).
        _exists: Injectable replacement for os.path.exists (testing).
        _isdir: Injectable replacement for os.path.isdir (testing).
        _readlink: Injectable replacement for os.readlink (testing).
        _run: Injectable replacement for subprocess.run (testing).
    """

    def __init__(
        self,
        state_mgr: StateManager,
        log_path: Optional[Path] = None,
        band_bloat_threshold: int = DEFAULT_BAND_BLOAT_THRESHOLD,
        swap_threshold_bytes: int = DEFAULT_SWAP_THRESHOLD_BYTES,
        snapshot_threshold_bytes: int = DEFAULT_SNAPSHOT_THRESHOLD_BYTES,
        *,
        _islink: _IsLinkFn = os.path.islink,
        _exists: _ExistsFn = os.path.exists,
        _isdir: _IsDirFn = os.path.isdir,
        _readlink: _ReadlinkFn = os.readlink,
        _run: _RunFn = _default_run,
    ) -> None:
        self._state_mgr = state_mgr
        self._log_path = log_path or DEFAULT_LOG_PATH
        self._band_bloat_threshold = band_bloat_threshold
        self._swap_threshold_bytes = swap_threshold_bytes
        self._snapshot_threshold_bytes = snapshot_threshold_bytes

        # Injected syscall / subprocess wrappers.
        self._islink = _islink
        self._exists = _exists
        self._isdir = _isdir
        self._readlink = _readlink
        self._run = _run

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def classify_drift(self) -> list[DriftEvent]:
        """Run a full dry-run classification pass and return all drift events.

        Side-effects:
        - Each event is appended as a JSON line to ``self._log_path``.
        - Nothing is repaired; this is read-only / observe-only.

        Returns:
            Ordered list of DriftEvent objects, oldest first.
        """
        events: list[DriftEvent] = []

        state = self._state_mgr.state

        # 1. Forest entry checks (per-link).
        for entry in state.forest:
            events.extend(self._classify_forest_entry(entry))

        # 2. Volume-level checks.
        for vol in state.volumes:
            events.extend(self._classify_volume(vol))

        # 3. System-wide pressure checks (independent of individual volumes).
        events.extend(self._classify_swap_pressure())
        events.extend(self._classify_snapshots())

        # Persist to JSONL log.
        self._append_jsonl(events)

        logger.info(
            "classify_drift complete: %d event(s) across %d forest entries, "
            "%d volumes",
            len(events),
            len(state.forest),
            len(state.volumes),
        )
        return events

    # ------------------------------------------------------------------
    # Forest entry classifiers
    # ------------------------------------------------------------------

    def _classify_forest_entry(self, entry: Any) -> list[DriftEvent]:
        """Return drift events for a single ForestEntry."""
        events: list[DriftEvent] = []
        path = entry.system_path

        if entry.expected_kind != ForestEntryKind.SYMLINK.value:
            # Only classify entries that should be symlinks.
            return events

        if not self._exists(path) and not self._islink(path):
            # Path absent entirely.
            events.append(
                DriftEvent(
                    category=DriftCategory.MISSING_LINK,
                    source=path,
                    detail=(
                        f"Expected symlink at '{path}' (volume={entry.volume}) "
                        "but path does not exist."
                    ),
                    severity="critical",
                )
            )
            return events

        if self._islink(path):
            # Symlink is present — check its target.
            try:
                target = self._readlink(path)
            except OSError as exc:
                events.append(
                    DriftEvent(
                        category=DriftCategory.STALE_TARGET,
                        source=path,
                        detail=f"os.readlink failed on '{path}': {exc}",
                        severity="warning",
                    )
                )
                return events

            if not self._exists(target):
                events.append(
                    DriftEvent(
                        category=DriftCategory.STALE_TARGET,
                        source=path,
                        detail=(
                            f"Symlink '{path}' points to '{target}' "
                            "but that target path does not exist."
                        ),
                        severity="warning",
                    )
                )
            return events

        # Path exists but is NOT a symlink.
        if self._isdir(path):
            events.append(
                DriftEvent(
                    category=DriftCategory.REAL_DIR_DRIFT,
                    source=path,
                    detail=(
                        f"'{path}' is a real directory; expected a symlink "
                        f"pointing into volume '{entry.volume}'."
                    ),
                    severity="warning",
                )
            )

        return events

    # ------------------------------------------------------------------
    # Volume classifiers
    # ------------------------------------------------------------------

    def _classify_volume(self, vol: Any) -> list[DriftEvent]:
        """Return drift events for a single VolumeEntry."""
        events: list[DriftEvent] = []

        # UNMOUNTED_VOL — mount_point not present as a directory.
        if not self._isdir(vol.mount_point):
            events.append(
                DriftEvent(
                    category=DriftCategory.UNMOUNTED_VOL,
                    source=vol.name,
                    detail=(
                        f"Volume '{vol.name}' mount_point '{vol.mount_point}' "
                        "is not a mounted directory."
                    ),
                    severity="critical",
                )
            )
            # Cannot do quota or band checks if the volume is not mounted.
            return events

        # OVERSIZED — used bytes exceeds quota.
        if vol.quota_bytes > 0 and vol.used_bytes > vol.quota_bytes:
            overage = vol.used_bytes - vol.quota_bytes
            events.append(
                DriftEvent(
                    category=DriftCategory.OVERSIZED,
                    source=vol.name,
                    detail=(
                        f"Volume '{vol.name}' used {vol.used_bytes:,} bytes "
                        f"exceeds quota {vol.quota_bytes:,} bytes "
                        f"(overage: {overage:,} bytes)."
                    ),
                    severity="warning",
                )
            )

        # BAND_BLOAT — count .band files inside the sparseimage bundle.
        events.extend(self._classify_band_bloat(vol))

        return events

    def _classify_band_bloat(self, vol: Any) -> list[DriftEvent]:
        """Check for excessive sparse-image band file count via diskutil info."""
        events: list[DriftEvent] = []

        # Ask diskutil for the image backing the mount point.  We look for a
        # "bands" directory under a recognised sparseimage bundle path.  The
        # heuristic: diskutil info <mount> returns "Image Path" for disk images.
        try:
            result = self._run(
                ["diskutil", "info", vol.mount_point],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return events

        image_path: Optional[str] = None
        for line in result.stdout.splitlines():
            if "Image Path" in line and ":" in line:
                image_path = line.split(":", 1)[1].strip()
                break

        if not image_path:
            return events

        # Bands directory lives inside the .sparseimage bundle.
        bands_dir = os.path.join(image_path, "bands")
        if not self._isdir(bands_dir):
            return events

        try:
            band_count = len(os.listdir(bands_dir))
        except OSError:
            return events

        if band_count > self._band_bloat_threshold:
            events.append(
                DriftEvent(
                    category=DriftCategory.BAND_BLOAT,
                    source=vol.name,
                    detail=(
                        f"Sparse image for volume '{vol.name}' has "
                        f"{band_count:,} band files "
                        f"(threshold: {self._band_bloat_threshold:,}). "
                        "Consider compacting."
                    ),
                    severity="warning",
                )
            )

        return events

    # ------------------------------------------------------------------
    # System-wide pressure classifiers
    # ------------------------------------------------------------------

    def _classify_swap_pressure(self) -> list[DriftEvent]:
        """Detect swap usage above threshold via sysctl vm.swapusage."""
        events: list[DriftEvent] = []

        try:
            result = self._run(
                ["sysctl", "vm.swapusage"],
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return events

        # Output format:
        #   vm.swapusage: total = 2048.00M  used = 512.25M  free = 1535.75M  ...
        used_bytes = self._parse_swap_used(result.stdout)
        if used_bytes is None:
            return events

        if used_bytes > self._swap_threshold_bytes:
            events.append(
                DriftEvent(
                    category=DriftCategory.SWAP_PRESSURE,
                    source="vm.swapusage",
                    detail=(
                        f"System swap used {used_bytes:,} bytes exceeds "
                        f"threshold {self._swap_threshold_bytes:,} bytes."
                    ),
                    severity="warning",
                )
            )

        return events

    @staticmethod
    def _parse_swap_used(sysctl_output: str) -> Optional[int]:
        """Parse the ``used`` field from ``sysctl vm.swapusage`` output.

        Expected format (from macOS sysctl)::

            vm.swapusage: total = 2048.00M  used = 512.25M  free = 1535.75M  ...

        Handles M (mebibytes) and G (gibibytes) suffixes.  Returns bytes or
        None if the output cannot be parsed.
        """
        import re

        # Targeted regex: match "used = <value><unit>" — anchored to the
        # "used" keyword so we never accidentally pick up "total" or "free".
        match = re.search(r"\bused\s*=\s*([\d.]+)\s*([MG])", sysctl_output, re.IGNORECASE)
        if match:
            value = float(match.group(1))
            unit = match.group(2).upper()
            multiplier = 1024 ** 2 if unit == "M" else 1024 ** 3
            return int(value * multiplier)

        return None

    def _classify_snapshots(self) -> list[DriftEvent]:
        """Detect APFS local snapshots consuming more than the threshold.

        Uses ``tmutil listlocalsnapshots /`` to enumerate snapshots and
        ``diskutil apfs listSnapshots`` to estimate size.  Falls back to
        counting only when size data is unavailable.
        """
        events: list[DriftEvent] = []

        try:
            result = self._run(
                ["tmutil", "listlocalsnapshots", "/"],
                capture_output=True,
                text=True,
                timeout=15,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return events

        snapshots = [
            line.strip()
            for line in result.stdout.splitlines()
            if line.strip().startswith("com.apple.TimeMachine")
        ]

        if not snapshots:
            return events

        # Attempt to get aggregate size from diskutil apfs listSnapshots.
        total_bytes = self._get_snapshot_total_bytes(snapshots)

        if total_bytes is not None:
            if total_bytes > self._snapshot_threshold_bytes:
                events.append(
                    DriftEvent(
                        category=DriftCategory.SNAPSHOT_LOCKED,
                        source="/",
                        detail=(
                            f"{len(snapshots)} local APFS snapshot(s) consuming "
                            f"~{total_bytes:,} bytes — exceeds threshold "
                            f"{self._snapshot_threshold_bytes:,} bytes. "
                            "Consider running 'tmutil deletelocalsnapshots /'."
                        ),
                        severity="warning",
                    )
                )
        else:
            # No size data — use snapshot count as a heuristic proxy.
            # Flag as info when we cannot determine actual size.
            if len(snapshots) > 0:
                events.append(
                    DriftEvent(
                        category=DriftCategory.SNAPSHOT_LOCKED,
                        source="/",
                        detail=(
                            f"{len(snapshots)} local APFS snapshot(s) found "
                            "on /. Size could not be determined — manual "
                            "review recommended."
                        ),
                        severity="info",
                    )
                )

        return events

    def _get_snapshot_total_bytes(
        self, snapshots: list[str]
    ) -> Optional[int]:
        """Return aggregate snapshot size in bytes by querying diskutil.

        Returns None when diskutil output cannot be parsed.
        """
        import re

        total = 0
        found_any = False

        try:
            result = self._run(
                ["diskutil", "apfs", "listSnapshots", "/"],
                capture_output=True,
                text=True,
                timeout=15,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return None

        for line in result.stdout.splitlines():
            # Lines like: "+-- Snapshot Disk Space Used:   1.23 GB (1320000000 Bytes)"
            match = re.search(r"\((\d+)\s+Bytes\)", line)
            if match:
                total += int(match.group(1))
                found_any = True

        return total if found_any else None

    # ------------------------------------------------------------------
    # JSONL logging
    # ------------------------------------------------------------------

    def _append_jsonl(self, events: list[DriftEvent]) -> None:
        """Append each event as a JSON line to the configured log file."""
        if not events:
            return
        try:
            self._log_path.parent.mkdir(parents=True, exist_ok=True)
            with open(self._log_path, "a", encoding="utf-8") as fh:
                for event in events:
                    fh.write(json.dumps(event.to_dict()) + "\n")
        except OSError as exc:
            logger.warning("Failed to write reconcile JSONL log: %s", exc)


# ---------------------------------------------------------------------------
# CLI entry point — invoked by the LaunchAgent.
# ---------------------------------------------------------------------------


def _main() -> None:
    import argparse

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    parser = argparse.ArgumentParser(
        description="LFG DevDrive v2 reconcile loop — dry-run drift classifier."
    )
    parser.add_argument(
        "--state",
        metavar="PATH",
        help="Path to devdrive_state.json (default: ~/.config/lfg/devdrive_state.json)",
    )
    parser.add_argument(
        "--log",
        metavar="PATH",
        help="Path to JSONL output log (default: ~/.config/lfg/reconcile_log.jsonl)",
    )
    parser.add_argument(
        "--band-threshold",
        type=int,
        default=DEFAULT_BAND_BLOAT_THRESHOLD,
        help=f"Band file count threshold (default: {DEFAULT_BAND_BLOAT_THRESHOLD})",
    )
    parser.add_argument(
        "--swap-threshold-gb",
        type=float,
        default=DEFAULT_SWAP_THRESHOLD_BYTES / 1024 ** 3,
        help="Swap threshold in GiB (default: 4.0)",
    )
    parser.add_argument(
        "--snapshot-threshold-gb",
        type=float,
        default=DEFAULT_SNAPSHOT_THRESHOLD_BYTES / 1024 ** 3,
        help="Snapshot threshold in GiB (default: 10.0)",
    )
    args = parser.parse_args()

    state_path = Path(args.state) if args.state else None
    log_path = Path(args.log) if args.log else None

    mgr = StateManager(path=state_path)
    loop = ReconcileLoop(
        state_mgr=mgr,
        log_path=log_path,
        band_bloat_threshold=args.band_threshold,
        swap_threshold_bytes=int(args.swap_threshold_gb * 1024 ** 3),
        snapshot_threshold_bytes=int(args.snapshot_threshold_gb * 1024 ** 3),
    )

    events = loop.classify_drift()
    for ev in events:
        print(json.dumps(ev.to_dict()))


if __name__ == "__main__":
    _main()

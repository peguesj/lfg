"""Tests for devdrive_v2.reconcile — one test class per DriftCategory.

Run with:
    PYTHONPATH=lib pytest lib/devdrive_v2/tests/test_reconcile.py -v

All filesystem and subprocess interactions are mocked; no real mounts or
system commands are exercised.
"""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest

from devdrive_v2.reconcile import (
    DEFAULT_BAND_BLOAT_THRESHOLD,
    DEFAULT_SNAPSHOT_THRESHOLD_BYTES,
    DEFAULT_SWAP_THRESHOLD_BYTES,
    DriftCategory,
    DriftEvent,
    ReconcileLoop,
)
from devdrive_v2.state import (
    ForestEntry,
    ForestEntryKind,
    StateManager,
    VolumeEntry,
    VolumeHealth,
)


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _make_state_mgr(
    tmp_path: Path,
    forest: list[ForestEntry] | None = None,
    volumes: list[VolumeEntry] | None = None,
) -> StateManager:
    """Build a StateManager pre-loaded with the given entries."""
    mgr = StateManager(path=tmp_path / "devdrive_state.json")
    mgr.load()
    for entry in forest or []:
        mgr.add_forest_entry(entry)
    for vol in volumes or []:
        mgr.add_volume(vol)
    return mgr


def _noop_run(*args: Any, **kwargs: Any) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
    """subprocess.run stub that returns empty output — nothing triggers."""
    return subprocess.CompletedProcess(args=args, returncode=0, stdout="", stderr="")


def _make_loop(
    mgr: StateManager,
    tmp_path: Path,
    *,
    islink: Any = lambda p: False,
    exists: Any = lambda p: True,
    isdir: Any = lambda p: True,
    readlink: Any = lambda p: "/Volumes/DDRV/target",
    run: Any = _noop_run,
    band_threshold: int = DEFAULT_BAND_BLOAT_THRESHOLD,
    swap_threshold: int = DEFAULT_SWAP_THRESHOLD_BYTES,
    snapshot_threshold: int = DEFAULT_SNAPSHOT_THRESHOLD_BYTES,
) -> ReconcileLoop:
    return ReconcileLoop(
        state_mgr=mgr,
        log_path=tmp_path / "reconcile_log.jsonl",
        band_bloat_threshold=band_threshold,
        swap_threshold_bytes=swap_threshold,
        snapshot_threshold_bytes=snapshot_threshold,
        _islink=islink,
        _exists=exists,
        _isdir=isdir,
        _readlink=readlink,
        _run=run,
    )


def _categories(events: list[DriftEvent]) -> list[DriftCategory]:
    return [e.category for e in events]


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def tmp_path_local(tmp_path: Path) -> Path:
    return tmp_path


# ---------------------------------------------------------------------------
# 1. MISSING_LINK
# ---------------------------------------------------------------------------


class TestMissingLink:
    """Symlink expected at system_path but path does not exist at all."""

    def test_missing_link_emitted(self, tmp_path: Path) -> None:
        entry = ForestEntry(
            id="fe-missing",
            system_path="/Users/j/.claude/projects",
            volume="DDRV904",
            target="/Volumes/DDRV904/projects",
            expected_kind=ForestEntryKind.SYMLINK.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])
        loop = _make_loop(
            mgr,
            tmp_path,
            islink=lambda p: False,   # not a symlink
            exists=lambda p: False,   # not present at all
            isdir=lambda p: False,
        )
        events = loop.classify_drift()
        assert DriftCategory.MISSING_LINK in _categories(events)

    def test_missing_link_severity_critical(self, tmp_path: Path) -> None:
        entry = ForestEntry(
            id="fe-crit",
            system_path="/tmp/ghost",
            volume="V1",
            target="/Volumes/V1/ghost",
            expected_kind=ForestEntryKind.SYMLINK.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])
        loop = _make_loop(mgr, tmp_path, islink=lambda p: False, exists=lambda p: False)
        events = [e for e in loop.classify_drift() if e.category == DriftCategory.MISSING_LINK]
        assert events[0].severity == "critical"

    def test_missing_link_source_is_system_path(self, tmp_path: Path) -> None:
        path = "/tmp/no-such-link"
        entry = ForestEntry(
            id="fe-src",
            system_path=path,
            volume="V1",
            target="/Volumes/V1/x",
            expected_kind=ForestEntryKind.SYMLINK.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])
        loop = _make_loop(mgr, tmp_path, islink=lambda p: False, exists=lambda p: False)
        events = [e for e in loop.classify_drift() if e.category == DriftCategory.MISSING_LINK]
        assert events[0].source == path

    def test_no_missing_link_when_symlink_present(self, tmp_path: Path) -> None:
        entry = ForestEntry(
            id="fe-ok",
            system_path="/tmp/good-link",
            volume="V1",
            target="/Volumes/V1/x",
            expected_kind=ForestEntryKind.SYMLINK.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])
        loop = _make_loop(
            mgr,
            tmp_path,
            islink=lambda p: True,
            exists=lambda p: True,
            readlink=lambda p: "/Volumes/V1/x",
        )
        assert DriftCategory.MISSING_LINK not in _categories(loop.classify_drift())


# ---------------------------------------------------------------------------
# 2. STALE_TARGET
# ---------------------------------------------------------------------------


class TestStaleTarget:
    """Symlink present but its target is gone."""

    def test_stale_target_emitted(self, tmp_path: Path) -> None:
        entry = ForestEntry(
            id="fe-stale",
            system_path="/tmp/stale-link",
            volume="DDRV904",
            target="/Volumes/DDRV904/projects",
            expected_kind=ForestEntryKind.SYMLINK.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])

        # The symlink itself exists (islink=True), but os.path.exists() follows
        # the link and returns False because the target is gone.  We model this
        # by returning False for the target path specifically.
        target = "/Volumes/DDRV904/projects"

        def _exists(p: str) -> bool:
            return p != target

        loop = _make_loop(
            mgr,
            tmp_path,
            islink=lambda p: p == "/tmp/stale-link",
            exists=_exists,
            readlink=lambda p: target,
        )
        events = loop.classify_drift()
        assert DriftCategory.STALE_TARGET in _categories(events)

    def test_stale_target_detail_contains_paths(self, tmp_path: Path) -> None:
        link_path = "/tmp/stale-link"
        target_path = "/Volumes/GONE/data"
        entry = ForestEntry(
            id="fe-stale2",
            system_path=link_path,
            volume="GONE",
            target=target_path,
            expected_kind=ForestEntryKind.SYMLINK.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])
        loop = _make_loop(
            mgr,
            tmp_path,
            islink=lambda p: True,
            exists=lambda p: False,
            readlink=lambda p: target_path,
        )
        events = [e for e in loop.classify_drift() if e.category == DriftCategory.STALE_TARGET]
        assert link_path in events[0].detail
        assert target_path in events[0].detail

    def test_stale_target_readlink_oserror(self, tmp_path: Path) -> None:
        """An OSError from readlink is also classified as STALE_TARGET."""
        entry = ForestEntry(
            id="fe-oserr",
            system_path="/tmp/broken-link",
            volume="V1",
            target="/Volumes/V1/x",
            expected_kind=ForestEntryKind.SYMLINK.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])

        def _bad_readlink(p: str) -> str:
            raise OSError("No such file or directory")

        loop = _make_loop(
            mgr,
            tmp_path,
            islink=lambda p: True,
            exists=lambda p: True,
            readlink=_bad_readlink,
        )
        events = loop.classify_drift()
        assert DriftCategory.STALE_TARGET in _categories(events)


# ---------------------------------------------------------------------------
# 3. REAL_DIR_DRIFT
# ---------------------------------------------------------------------------


class TestRealDirDrift:
    """Expected symlink but found a real directory."""

    def test_real_dir_drift_emitted(self, tmp_path: Path) -> None:
        entry = ForestEntry(
            id="fe-realdir",
            system_path="/tmp/real-dir",
            volume="DDRV904",
            target="/Volumes/DDRV904/data",
            expected_kind=ForestEntryKind.SYMLINK.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])
        loop = _make_loop(
            mgr,
            tmp_path,
            islink=lambda p: False,   # NOT a symlink
            exists=lambda p: True,    # path exists
            isdir=lambda p: True,     # it's a real directory
        )
        events = loop.classify_drift()
        assert DriftCategory.REAL_DIR_DRIFT in _categories(events)

    def test_real_dir_drift_severity_warning(self, tmp_path: Path) -> None:
        entry = ForestEntry(
            id="fe-realdir2",
            system_path="/tmp/real-dir",
            volume="V1",
            target="/Volumes/V1/data",
            expected_kind=ForestEntryKind.SYMLINK.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])
        loop = _make_loop(
            mgr,
            tmp_path,
            islink=lambda p: False,
            exists=lambda p: True,
            isdir=lambda p: True,
        )
        events = [e for e in loop.classify_drift() if e.category == DriftCategory.REAL_DIR_DRIFT]
        assert events[0].severity == "warning"

    def test_real_dir_drift_not_emitted_for_symlink(self, tmp_path: Path) -> None:
        entry = ForestEntry(
            id="fe-ok2",
            system_path="/tmp/good-link2",
            volume="V1",
            target="/Volumes/V1/x",
            expected_kind=ForestEntryKind.SYMLINK.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])
        loop = _make_loop(
            mgr,
            tmp_path,
            islink=lambda p: True,
            exists=lambda p: True,
            readlink=lambda p: "/Volumes/V1/x",
        )
        assert DriftCategory.REAL_DIR_DRIFT not in _categories(loop.classify_drift())


# ---------------------------------------------------------------------------
# 4. UNMOUNTED_VOL
# ---------------------------------------------------------------------------


class TestUnmountedVol:
    """Volume registered in state but its mount point is not a directory."""

    def test_unmounted_vol_emitted(self, tmp_path: Path) -> None:
        vol = VolumeEntry(
            name="DDRV900",
            mount_point="/Volumes/DDRV900",
            health=VolumeHealth.UNMOUNTED.value,
        )
        mgr = _make_state_mgr(tmp_path, volumes=[vol])
        loop = _make_loop(
            mgr,
            tmp_path,
            isdir=lambda p: False,   # mount point is NOT a directory
        )
        events = loop.classify_drift()
        assert DriftCategory.UNMOUNTED_VOL in _categories(events)

    def test_unmounted_vol_severity_critical(self, tmp_path: Path) -> None:
        vol = VolumeEntry(name="V99", mount_point="/Volumes/V99")
        mgr = _make_state_mgr(tmp_path, volumes=[vol])
        loop = _make_loop(mgr, tmp_path, isdir=lambda p: False)
        events = [e for e in loop.classify_drift() if e.category == DriftCategory.UNMOUNTED_VOL]
        assert events[0].severity == "critical"

    def test_unmounted_vol_source_is_volume_name(self, tmp_path: Path) -> None:
        vol = VolumeEntry(name="MYVOLUME", mount_point="/Volumes/MYVOLUME")
        mgr = _make_state_mgr(tmp_path, volumes=[vol])
        loop = _make_loop(mgr, tmp_path, isdir=lambda p: False)
        events = [e for e in loop.classify_drift() if e.category == DriftCategory.UNMOUNTED_VOL]
        assert events[0].source == "MYVOLUME"

    def test_mounted_vol_no_unmounted_event(self, tmp_path: Path) -> None:
        vol = VolumeEntry(
            name="DDRV900",
            mount_point="/Volumes/DDRV900",
            quota_bytes=100,
            used_bytes=50,
        )
        mgr = _make_state_mgr(tmp_path, volumes=[vol])
        loop = _make_loop(mgr, tmp_path, isdir=lambda p: True)
        assert DriftCategory.UNMOUNTED_VOL not in _categories(loop.classify_drift())


# ---------------------------------------------------------------------------
# 5. OVERSIZED
# ---------------------------------------------------------------------------


class TestOversized:
    """Volume used_bytes exceeds quota_bytes."""

    def test_oversized_emitted(self, tmp_path: Path) -> None:
        vol = VolumeEntry(
            name="DDRV901",
            mount_point="/Volumes/DDRV901",
            quota_bytes=100_000_000,
            used_bytes=120_000_000,
        )
        mgr = _make_state_mgr(tmp_path, volumes=[vol])
        loop = _make_loop(mgr, tmp_path, isdir=lambda p: True)
        events = loop.classify_drift()
        assert DriftCategory.OVERSIZED in _categories(events)

    def test_oversized_detail_contains_bytes(self, tmp_path: Path) -> None:
        vol = VolumeEntry(
            name="DDRV901",
            mount_point="/Volumes/DDRV901",
            quota_bytes=100_000_000,
            used_bytes=120_000_000,
        )
        mgr = _make_state_mgr(tmp_path, volumes=[vol])
        loop = _make_loop(mgr, tmp_path, isdir=lambda p: True)
        events = [e for e in loop.classify_drift() if e.category == DriftCategory.OVERSIZED]
        assert "120,000,000" in events[0].detail
        assert "100,000,000" in events[0].detail

    def test_not_oversized_when_within_quota(self, tmp_path: Path) -> None:
        vol = VolumeEntry(
            name="DDRV901",
            mount_point="/Volumes/DDRV901",
            quota_bytes=100_000_000,
            used_bytes=80_000_000,
        )
        mgr = _make_state_mgr(tmp_path, volumes=[vol])
        loop = _make_loop(mgr, tmp_path, isdir=lambda p: True)
        assert DriftCategory.OVERSIZED not in _categories(loop.classify_drift())

    def test_not_oversized_when_no_quota(self, tmp_path: Path) -> None:
        """quota_bytes=0 means unconstrained — should not trigger OVERSIZED."""
        vol = VolumeEntry(
            name="DDRV901",
            mount_point="/Volumes/DDRV901",
            quota_bytes=0,
            used_bytes=999_999_999,
        )
        mgr = _make_state_mgr(tmp_path, volumes=[vol])
        loop = _make_loop(mgr, tmp_path, isdir=lambda p: True)
        assert DriftCategory.OVERSIZED not in _categories(loop.classify_drift())


# ---------------------------------------------------------------------------
# 6. BAND_BLOAT
# ---------------------------------------------------------------------------


class TestBandBloat:
    """Sparse-image band file count exceeds threshold."""

    def _run_with_image(
        self,
        image_path: str,
        band_count: int,
        tmp_path: Path,
    ) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
        diskutil_output = (
            f"   Image Path:               {image_path}\n"
            "   Mounted:                  Yes\n"
        )

        def _run(*args: Any, **kwargs: Any) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
            cmd = args[0] if args else kwargs.get("args", [])
            if isinstance(cmd, list) and "diskutil" in cmd and "info" in cmd:
                return subprocess.CompletedProcess(
                    args=cmd, returncode=0, stdout=diskutil_output, stderr=""
                )
            return subprocess.CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

        return _run

    def test_band_bloat_emitted(self, tmp_path: Path) -> None:
        # Create a fake bands directory with many files.
        image_dir = tmp_path / "MyVol.sparseimage"
        bands_dir = image_dir / "bands"
        bands_dir.mkdir(parents=True)
        threshold = 100
        for i in range(threshold + 10):
            (bands_dir / f"{i:08x}").touch()

        vol = VolumeEntry(name="DDRV902", mount_point="/Volumes/DDRV902")
        mgr = _make_state_mgr(tmp_path, volumes=[vol])

        run_fn = self._run_with_image(str(image_dir), threshold + 10, tmp_path)

        # isdir must return True for both the mount point AND the bands dir.
        def _isdir(p: str) -> bool:
            return True

        loop = ReconcileLoop(
            state_mgr=mgr,
            log_path=tmp_path / "reconcile_log.jsonl",
            band_bloat_threshold=threshold,
            _islink=lambda p: False,
            _exists=lambda p: True,
            _isdir=_isdir,
            _readlink=lambda p: "",
            _run=run_fn,
        )
        events = loop.classify_drift()
        assert DriftCategory.BAND_BLOAT in _categories(events)

    def test_band_bloat_not_emitted_below_threshold(self, tmp_path: Path) -> None:
        image_dir = tmp_path / "Small.sparseimage"
        bands_dir = image_dir / "bands"
        bands_dir.mkdir(parents=True)
        threshold = 1000
        for i in range(5):  # far below threshold
            (bands_dir / f"{i:08x}").touch()

        vol = VolumeEntry(name="DDRV902", mount_point="/Volumes/DDRV902")
        mgr = _make_state_mgr(tmp_path, volumes=[vol])
        run_fn = self._run_with_image(str(image_dir), 5, tmp_path)

        loop = ReconcileLoop(
            state_mgr=mgr,
            log_path=tmp_path / "reconcile_log.jsonl",
            band_bloat_threshold=threshold,
            _islink=lambda p: False,
            _exists=lambda p: True,
            _isdir=lambda p: True,
            _readlink=lambda p: "",
            _run=run_fn,
        )
        assert DriftCategory.BAND_BLOAT not in _categories(loop.classify_drift())

    def test_band_bloat_no_event_when_diskutil_unavailable(self, tmp_path: Path) -> None:
        """FileNotFoundError from diskutil should be swallowed silently."""
        vol = VolumeEntry(name="DDRV902", mount_point="/Volumes/DDRV902")
        mgr = _make_state_mgr(tmp_path, volumes=[vol])

        def _run_raises(*args: Any, **kwargs: Any) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
            raise FileNotFoundError("diskutil not found")

        loop = _make_loop(
            mgr, tmp_path, isdir=lambda p: True, run=_run_raises, band_threshold=10
        )
        # Should not raise; BAND_BLOAT simply not emitted.
        events = loop.classify_drift()
        assert DriftCategory.BAND_BLOAT not in _categories(events)


# ---------------------------------------------------------------------------
# 7. SNAPSHOT_LOCKED
# ---------------------------------------------------------------------------


class TestSnapshotLocked:
    """APFS local snapshots consuming more than the threshold."""

    def _make_tmutil_run(
        self,
        snapshots: list[str],
        snapshot_bytes: int | None,
    ) -> Any:
        tmutil_output = "\n".join(snapshots) + "\n" if snapshots else ""

        if snapshot_bytes is not None:
            diskutil_output = (
                f"+-- Snapshot Disk Space Used:   1.00 GB ({snapshot_bytes} Bytes)\n"
            )
        else:
            diskutil_output = "No snapshots found.\n"

        def _run(*args: Any, **kwargs: Any) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
            cmd = args[0] if args else kwargs.get("args", [])
            if isinstance(cmd, list):
                if "tmutil" in cmd:
                    return subprocess.CompletedProcess(
                        args=cmd, returncode=0, stdout=tmutil_output, stderr=""
                    )
                if "diskutil" in cmd and "apfs" in cmd:
                    return subprocess.CompletedProcess(
                        args=cmd, returncode=0, stdout=diskutil_output, stderr=""
                    )
            return subprocess.CompletedProcess(args=cmd, returncode=0, stdout="", stderr="")

        return _run

    def test_snapshot_locked_emitted(self, tmp_path: Path) -> None:
        large_bytes = DEFAULT_SNAPSHOT_THRESHOLD_BYTES + 1
        snapshots = ["com.apple.TimeMachine.2026-04-14-120000"]
        run_fn = self._make_tmutil_run(snapshots, large_bytes)

        mgr = _make_state_mgr(tmp_path)
        loop = _make_loop(mgr, tmp_path, run=run_fn)
        events = loop.classify_drift()
        assert DriftCategory.SNAPSHOT_LOCKED in _categories(events)

    def test_snapshot_locked_severity_warning(self, tmp_path: Path) -> None:
        large_bytes = DEFAULT_SNAPSHOT_THRESHOLD_BYTES + 1
        snapshots = ["com.apple.TimeMachine.2026-04-14-120000"]
        run_fn = self._make_tmutil_run(snapshots, large_bytes)

        mgr = _make_state_mgr(tmp_path)
        loop = _make_loop(mgr, tmp_path, run=run_fn)
        events = [e for e in loop.classify_drift() if e.category == DriftCategory.SNAPSHOT_LOCKED]
        assert events[0].severity == "warning"

    def test_snapshot_locked_not_emitted_below_threshold(self, tmp_path: Path) -> None:
        small_bytes = DEFAULT_SNAPSHOT_THRESHOLD_BYTES - 1
        snapshots = ["com.apple.TimeMachine.2026-04-14-120000"]
        run_fn = self._make_tmutil_run(snapshots, small_bytes)

        mgr = _make_state_mgr(tmp_path)
        loop = _make_loop(mgr, tmp_path, run=run_fn)
        assert DriftCategory.SNAPSHOT_LOCKED not in _categories(loop.classify_drift())

    def test_snapshot_locked_info_when_size_unknown(self, tmp_path: Path) -> None:
        """When diskutil returns no byte data, emit info-level event."""
        snapshots = ["com.apple.TimeMachine.2026-04-14-120000"]
        run_fn = self._make_tmutil_run(snapshots, snapshot_bytes=None)

        mgr = _make_state_mgr(tmp_path)
        loop = _make_loop(mgr, tmp_path, run=run_fn)
        events = [e for e in loop.classify_drift() if e.category == DriftCategory.SNAPSHOT_LOCKED]
        assert len(events) == 1
        assert events[0].severity == "info"

    def test_no_snapshot_event_when_no_snapshots(self, tmp_path: Path) -> None:
        run_fn = self._make_tmutil_run([], snapshot_bytes=None)
        mgr = _make_state_mgr(tmp_path)
        loop = _make_loop(mgr, tmp_path, run=run_fn)
        assert DriftCategory.SNAPSHOT_LOCKED not in _categories(loop.classify_drift())

    def test_snapshot_locked_tmutil_not_available(self, tmp_path: Path) -> None:
        """FileNotFoundError from tmutil should be silently swallowed."""
        def _run_raises(*args: Any, **kwargs: Any) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
            raise FileNotFoundError("tmutil not found")

        mgr = _make_state_mgr(tmp_path)
        loop = _make_loop(mgr, tmp_path, run=_run_raises)
        events = loop.classify_drift()
        assert DriftCategory.SNAPSHOT_LOCKED not in _categories(events)


# ---------------------------------------------------------------------------
# 8. SWAP_PRESSURE
# ---------------------------------------------------------------------------


class TestSwapPressure:
    """System swap usage exceeds threshold."""

    def _make_sysctl_run(self, used_mb: float) -> Any:
        output = (
            f"vm.swapusage: total = 2048.00M  used = {used_mb:.2f}M  "
            f"free = {2048.0 - used_mb:.2f}M  (encrypted)\n"
        )

        def _run(*args: Any, **kwargs: Any) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
            return subprocess.CompletedProcess(
                args=args, returncode=0, stdout=output, stderr=""
            )

        return _run

    def test_swap_pressure_emitted(self, tmp_path: Path) -> None:
        threshold_mb = DEFAULT_SWAP_THRESHOLD_BYTES / 1024 ** 2
        run_fn = self._make_sysctl_run(threshold_mb + 100)

        mgr = _make_state_mgr(tmp_path)
        loop = _make_loop(mgr, tmp_path, run=run_fn)
        events = loop.classify_drift()
        assert DriftCategory.SWAP_PRESSURE in _categories(events)

    def test_swap_pressure_severity_warning(self, tmp_path: Path) -> None:
        threshold_mb = DEFAULT_SWAP_THRESHOLD_BYTES / 1024 ** 2
        run_fn = self._make_sysctl_run(threshold_mb + 100)

        mgr = _make_state_mgr(tmp_path)
        loop = _make_loop(mgr, tmp_path, run=run_fn)
        events = [e for e in loop.classify_drift() if e.category == DriftCategory.SWAP_PRESSURE]
        assert events[0].severity == "warning"

    def test_swap_pressure_not_emitted_below_threshold(self, tmp_path: Path) -> None:
        threshold_mb = DEFAULT_SWAP_THRESHOLD_BYTES / 1024 ** 2
        run_fn = self._make_sysctl_run(threshold_mb - 100)

        mgr = _make_state_mgr(tmp_path)
        loop = _make_loop(mgr, tmp_path, run=run_fn)
        assert DriftCategory.SWAP_PRESSURE not in _categories(loop.classify_drift())

    def test_swap_pressure_source_is_vm_swapusage(self, tmp_path: Path) -> None:
        threshold_mb = DEFAULT_SWAP_THRESHOLD_BYTES / 1024 ** 2
        run_fn = self._make_sysctl_run(threshold_mb + 1)

        mgr = _make_state_mgr(tmp_path)
        loop = _make_loop(mgr, tmp_path, run=run_fn)
        events = [e for e in loop.classify_drift() if e.category == DriftCategory.SWAP_PRESSURE]
        assert events[0].source == "vm.swapusage"

    def test_swap_pressure_parse_gigabytes(self, tmp_path: Path) -> None:
        """sysctl output using G suffix should also be parsed correctly."""
        output = "vm.swapusage: total = 8.00G  used = 5.00G  free = 3.00G  (encrypted)\n"

        def _run(*args: Any, **kwargs: Any) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
            return subprocess.CompletedProcess(
                args=args, returncode=0, stdout=output, stderr=""
            )

        mgr = _make_state_mgr(tmp_path)
        # Threshold of 4 GiB; 5 GiB used should fire.
        loop = _make_loop(
            mgr, tmp_path, run=_run, swap_threshold=4 * 1024 ** 3
        )
        assert DriftCategory.SWAP_PRESSURE in _categories(loop.classify_drift())

    def test_swap_pressure_sysctl_not_available(self, tmp_path: Path) -> None:
        """FileNotFoundError from sysctl should be silently swallowed."""
        def _run_raises(*args: Any, **kwargs: Any) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
            raise FileNotFoundError("sysctl not found")

        mgr = _make_state_mgr(tmp_path)
        loop = _make_loop(mgr, tmp_path, run=_run_raises)
        events = loop.classify_drift()
        assert DriftCategory.SWAP_PRESSURE not in _categories(events)


# ---------------------------------------------------------------------------
# Cross-cutting: JSONL log output
# ---------------------------------------------------------------------------


class TestJsonlLog:
    """classify_drift must append one JSON line per drift event to the log."""

    def test_jsonl_written_for_each_event(self, tmp_path: Path) -> None:
        entry = ForestEntry(
            id="fe-log",
            system_path="/tmp/no-link",
            volume="V1",
            target="/Volumes/V1/x",
            expected_kind=ForestEntryKind.SYMLINK.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])
        log_path = tmp_path / "reconcile_log.jsonl"
        loop = ReconcileLoop(
            state_mgr=mgr,
            log_path=log_path,
            _islink=lambda p: False,
            _exists=lambda p: False,
            _isdir=lambda p: False,
            _readlink=lambda p: "",
            _run=_noop_run,
        )
        events = loop.classify_drift()

        assert log_path.exists()
        lines = log_path.read_text().strip().splitlines()
        assert len(lines) == len(events)

        # Each line must be valid JSON with the expected keys.
        for line in lines:
            record = json.loads(line)
            assert "category" in record
            assert "source" in record
            assert "detail" in record
            assert "severity" in record
            assert "ts" in record

    def test_jsonl_appends_across_calls(self, tmp_path: Path) -> None:
        """Multiple classify_drift calls should append, not overwrite."""
        entry = ForestEntry(
            id="fe-append",
            system_path="/tmp/no-link2",
            volume="V1",
            target="/Volumes/V1/x",
            expected_kind=ForestEntryKind.SYMLINK.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])
        log_path = tmp_path / "reconcile_log.jsonl"
        loop = ReconcileLoop(
            state_mgr=mgr,
            log_path=log_path,
            _islink=lambda p: False,
            _exists=lambda p: False,
            _isdir=lambda p: False,
            _readlink=lambda p: "",
            _run=_noop_run,
        )
        loop.classify_drift()
        loop.classify_drift()

        lines = log_path.read_text().strip().splitlines()
        # Two runs × at least 1 event each.
        assert len(lines) >= 2


# ---------------------------------------------------------------------------
# Cross-cutting: non-symlink entries are skipped
# ---------------------------------------------------------------------------


class TestNonSymlinkEntriesSkipped:
    """Forest entries expected to be directories should not raise forest drift."""

    def test_directory_expected_kind_no_events(self, tmp_path: Path) -> None:
        entry = ForestEntry(
            id="fe-dir-kind",
            system_path="/tmp/real-folder",
            volume="V1",
            target="/Volumes/V1/folder",
            expected_kind=ForestEntryKind.DIRECTORY.value,
        )
        mgr = _make_state_mgr(tmp_path, forest=[entry])
        loop = _make_loop(
            mgr,
            tmp_path,
            islink=lambda p: False,
            exists=lambda p: True,
            isdir=lambda p: True,
        )
        events = loop.classify_drift()
        forest_categories = {
            DriftCategory.MISSING_LINK,
            DriftCategory.STALE_TARGET,
            DriftCategory.REAL_DIR_DRIFT,
        }
        assert not any(e.category in forest_categories for e in events)

"""Tests for devdrive_v2.actions — repair action functions (US-003).

Run with:
    PYTHONPATH=lib pytest lib/devdrive_v2/tests/test_actions.py -v

All filesystem and subprocess interactions are mocked; no real mounts,
symlinks, or system commands are executed.
"""

from __future__ import annotations

import subprocess
from typing import Any
from unittest.mock import MagicMock, call, patch

import pytest

from devdrive_v2.actions import (
    ActionResult,
    dispatch_action,
    fix_band_bloat,
    fix_missing_link,
    fix_real_dir_drift,
    fix_snapshot_locked,
    fix_stale_target,
    fix_unmounted_vol,
    lsof_check,
)
from devdrive_v2.reconcile import DriftCategory, DriftEvent


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _completed(
    stdout: str = "",
    stderr: str = "",
    returncode: int = 0,
    args: list[str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Build a fake CompletedProcess for mock return values."""
    return subprocess.CompletedProcess(
        args=args or [],
        returncode=returncode,
        stdout=stdout,
        stderr=stderr,
    )


def _event(
    category: DriftCategory,
    source: str = "/tmp/test-path",
    detail: str = "",
    severity: str = "warning",
) -> DriftEvent:
    """Build a minimal DriftEvent for testing."""
    return DriftEvent(
        category=category,
        source=source,
        detail=detail,
        severity=severity,
    )


# ---------------------------------------------------------------------------
# lsof_check
# ---------------------------------------------------------------------------


class TestLsofCheck:
    """Unit tests for the lsof_check helper."""

    def test_returns_true_when_handles_open(self) -> None:
        with patch("devdrive_v2.actions._run") as mock_run:
            mock_run.return_value = _completed(stdout="some process output\n")
            assert lsof_check("/tmp/busy") is True
            mock_run.assert_called_once_with(["lsof", "+D", "/tmp/busy"], timeout=15)

    def test_returns_false_when_no_handles(self) -> None:
        with patch("devdrive_v2.actions._run") as mock_run:
            mock_run.return_value = _completed(stdout="")
            assert lsof_check("/tmp/free") is False

    def test_returns_false_on_file_not_found(self) -> None:
        with patch("devdrive_v2.actions._run") as mock_run:
            mock_run.side_effect = FileNotFoundError("lsof not found")
            assert lsof_check("/tmp/any") is False

    def test_returns_false_on_timeout(self) -> None:
        with patch("devdrive_v2.actions._run") as mock_run:
            mock_run.side_effect = subprocess.TimeoutExpired(cmd="lsof", timeout=15)
            assert lsof_check("/tmp/any") is False

    def test_returns_false_on_oserror(self) -> None:
        with patch("devdrive_v2.actions._run") as mock_run:
            mock_run.side_effect = OSError("permission denied")
            assert lsof_check("/tmp/any") is False

    def test_whitespace_only_stdout_treated_as_empty(self) -> None:
        with patch("devdrive_v2.actions._run") as mock_run:
            mock_run.return_value = _completed(stdout="   \n  ")
            assert lsof_check("/tmp/free2") is False


# ---------------------------------------------------------------------------
# fix_missing_link
# ---------------------------------------------------------------------------


class TestFixMissingLink:
    """Tests for fix_missing_link."""

    _DETAIL = "Expected symlink at '/tmp/my-link' (volume=VOL1) but path does not exist."
    _TARGET = "/Volumes/VOL1/data"
    _DETAIL_WITH_TARGET = (
        f"Expected symlink at '/tmp/my-link', target='{_TARGET}'"
    )

    def _event_with_target(self, system_path: str = "/tmp/my-link") -> DriftEvent:
        return _event(
            category=DriftCategory.MISSING_LINK,
            source=system_path,
            detail=f"Expected symlink at '{system_path}', target='{self._TARGET}'",
        )

    # -- dry-run mode --------------------------------------------------------

    def test_dry_run_returns_dry_run_true(self) -> None:
        ev = self._event_with_target()
        result = fix_missing_link(ev, dry_run=True)
        assert result.dry_run is True

    def test_dry_run_success_true(self) -> None:
        ev = self._event_with_target()
        result = fix_missing_link(ev, dry_run=True)
        assert result.success is True

    def test_dry_run_detail_contains_dry_run_marker(self) -> None:
        ev = self._event_with_target()
        result = fix_missing_link(ev, dry_run=True)
        assert "[dry-run]" in result.detail

    def test_dry_run_detail_contains_target_path(self) -> None:
        ev = self._event_with_target()
        result = fix_missing_link(ev, dry_run=True)
        assert self._TARGET in result.detail

    def test_dry_run_no_os_calls(self) -> None:
        ev = self._event_with_target()
        with patch("os.symlink") as mock_symlink, patch("os.makedirs") as mock_makedirs:
            fix_missing_link(ev, dry_run=True)
            mock_symlink.assert_not_called()
            mock_makedirs.assert_not_called()

    def test_dry_run_action_name(self) -> None:
        ev = self._event_with_target()
        result = fix_missing_link(ev, dry_run=True)
        assert result.action == "fix_missing_link"

    def test_dry_run_source_is_system_path(self) -> None:
        ev = self._event_with_target("/tmp/check-source")
        result = fix_missing_link(ev, dry_run=True)
        assert result.source == "/tmp/check-source"

    def test_dry_run_no_parseable_target_returns_failure(self) -> None:
        ev = _event(
            category=DriftCategory.MISSING_LINK,
            source="/tmp/ghost",
            detail="No path info here at all.",
        )
        result = fix_missing_link(ev, dry_run=True)
        assert result.success is False

    # -- apply mode ----------------------------------------------------------

    def test_apply_calls_os_symlink(self) -> None:
        ev = self._event_with_target("/tmp/apply-link")
        with (
            patch("devdrive_v2.actions.os.makedirs"),
            patch("devdrive_v2.actions.os.path.islink", return_value=False),
            patch("devdrive_v2.actions.os.symlink") as mock_symlink,
        ):
            result = fix_missing_link(ev, dry_run=False)
        mock_symlink.assert_called_once_with(self._TARGET, "/tmp/apply-link")
        assert result.success is True
        assert result.dry_run is False

    def test_apply_removes_existing_broken_symlink_first(self) -> None:
        ev = self._event_with_target("/tmp/broken-first")
        with (
            patch("devdrive_v2.actions.os.makedirs"),
            patch("devdrive_v2.actions.os.path.islink", return_value=True),
            patch("devdrive_v2.actions.os.unlink") as mock_unlink,
            patch("devdrive_v2.actions.os.symlink"),
        ):
            fix_missing_link(ev, dry_run=False)
        mock_unlink.assert_called_once_with("/tmp/broken-first")

    def test_apply_oserror_returns_failure(self) -> None:
        ev = self._event_with_target("/tmp/fail-link")
        with (
            patch("devdrive_v2.actions.os.makedirs"),
            patch("devdrive_v2.actions.os.path.islink", return_value=False),
            patch("devdrive_v2.actions.os.symlink", side_effect=OSError("permission denied")),
        ):
            result = fix_missing_link(ev, dry_run=False)
        assert result.success is False
        assert "permission denied" in result.detail


# ---------------------------------------------------------------------------
# fix_stale_target
# ---------------------------------------------------------------------------


class TestFixStaleTarget:
    """Tests for fix_stale_target."""

    _SYSTEM_PATH = "/tmp/stale-link"
    _TARGET = "/Volumes/GONE/data"
    _DETAIL = f"Symlink '{_SYSTEM_PATH}' points to '{_TARGET}' but that target path does not exist."

    def _ev(self) -> DriftEvent:
        return _event(
            category=DriftCategory.STALE_TARGET,
            source=self._SYSTEM_PATH,
            detail=self._DETAIL,
        )

    # -- dry-run -------------------------------------------------------------

    def test_dry_run_true_flag(self) -> None:
        result = fix_stale_target(self._ev(), dry_run=True)
        assert result.dry_run is True

    def test_dry_run_success_true(self) -> None:
        result = fix_stale_target(self._ev(), dry_run=True)
        assert result.success is True

    def test_dry_run_no_filesystem_calls(self) -> None:
        with patch("os.unlink") as mock_unlink, patch("os.symlink") as mock_symlink:
            fix_stale_target(self._ev(), dry_run=True)
            mock_unlink.assert_not_called()
            mock_symlink.assert_not_called()

    def test_dry_run_detail_contains_dry_run_marker(self) -> None:
        result = fix_stale_target(self._ev(), dry_run=True)
        assert "[dry-run]" in result.detail

    def test_dry_run_action_name(self) -> None:
        result = fix_stale_target(self._ev(), dry_run=True)
        assert result.action == "fix_stale_target"

    # -- apply: target not reachable ----------------------------------------

    def test_apply_removes_symlink_when_target_gone(self) -> None:
        with (
            patch("devdrive_v2.actions.os.path.exists", return_value=False),
            patch("devdrive_v2.actions.os.path.islink", return_value=True),
            patch("devdrive_v2.actions.os.unlink") as mock_unlink,
            patch("devdrive_v2.actions.os.symlink") as mock_symlink,
        ):
            result = fix_stale_target(self._ev(), dry_run=False)
        mock_unlink.assert_called_once_with(self._SYSTEM_PATH)
        mock_symlink.assert_not_called()
        assert result.success is True

    # -- apply: target reachable (volume now mounted) -----------------------

    def test_apply_recreates_symlink_when_target_available(self) -> None:
        with (
            patch("devdrive_v2.actions.os.path.exists", return_value=True),
            patch("devdrive_v2.actions.os.path.islink", return_value=True),
            patch("devdrive_v2.actions.os.unlink"),
            patch("devdrive_v2.actions.os.symlink") as mock_symlink,
        ):
            result = fix_stale_target(self._ev(), dry_run=False)
        mock_symlink.assert_called_once_with(self._TARGET, self._SYSTEM_PATH)
        assert result.success is True

    def test_apply_unlink_oserror_returns_failure(self) -> None:
        with (
            patch("devdrive_v2.actions.os.path.exists", return_value=False),
            patch("devdrive_v2.actions.os.path.islink", return_value=True),
            patch("devdrive_v2.actions.os.unlink", side_effect=OSError("eperm")),
        ):
            result = fix_stale_target(self._ev(), dry_run=False)
        assert result.success is False
        assert "eperm" in result.detail


# ---------------------------------------------------------------------------
# fix_real_dir_drift
# ---------------------------------------------------------------------------


class TestFixRealDirDrift:
    """Tests for fix_real_dir_drift."""

    _SYSTEM_PATH = "/tmp/real-dir"
    _TARGET = "/Volumes/DDRV904/data"
    _DETAIL = f"'{_SYSTEM_PATH}' is a real directory; expected a symlink pointing into volume '{_TARGET}'."

    def _ev(self) -> DriftEvent:
        return _event(
            category=DriftCategory.REAL_DIR_DRIFT,
            source=self._SYSTEM_PATH,
            detail=self._DETAIL,
        )

    # -- lsof blocks the action ----------------------------------------------

    def test_lsof_blocking_dry_run_returns_failure(self) -> None:
        """lsof check should block the action even in dry-run."""
        with patch("devdrive_v2.actions.lsof_check", return_value=True):
            result = fix_real_dir_drift(self._ev(), dry_run=True)
        assert result.success is False
        assert "lsof" in result.detail.lower() or "open file" in result.detail.lower()

    def test_lsof_blocking_apply_returns_failure(self) -> None:
        with patch("devdrive_v2.actions.lsof_check", return_value=True):
            result = fix_real_dir_drift(self._ev(), dry_run=False)
        assert result.success is False

    # -- dry-run (no lsof block) --------------------------------------------

    def test_dry_run_no_subprocess_calls(self) -> None:
        with (
            patch("devdrive_v2.actions.lsof_check", return_value=False),
            patch("devdrive_v2.actions._run") as mock_run,
            patch("os.rename"),
            patch("os.symlink"),
        ):
            result = fix_real_dir_drift(self._ev(), dry_run=True)
            mock_run.assert_not_called()
        assert result.dry_run is True
        assert result.success is True

    def test_dry_run_detail_mentions_rsync_and_diff(self) -> None:
        with patch("devdrive_v2.actions.lsof_check", return_value=False):
            result = fix_real_dir_drift(self._ev(), dry_run=True)
        assert "rsync" in result.detail
        assert "diff" in result.detail or "checksum" in result.detail.lower()

    def test_dry_run_action_name(self) -> None:
        with patch("devdrive_v2.actions.lsof_check", return_value=False):
            result = fix_real_dir_drift(self._ev(), dry_run=True)
        assert result.action == "fix_real_dir_drift"

    # -- apply mode ---------------------------------------------------------

    def test_apply_calls_rsync_and_diff(self) -> None:
        with (
            patch("devdrive_v2.actions.lsof_check", return_value=False),
            patch("devdrive_v2.actions._run") as mock_run,
            patch("os.rename"),
            patch("os.symlink"),
        ):
            mock_run.side_effect = [
                _completed(stdout="rsync output"),   # rsync call
                _completed(stdout=""),               # diff call (no differences)
            ]
            result = fix_real_dir_drift(self._ev(), dry_run=False)

        calls = mock_run.call_args_list
        assert any("rsync" in call.args[0][0] for call in calls), "rsync not called"
        assert any("diff" in call.args[0][0] for call in calls), "diff not called"
        assert result.success is True
        assert result.dry_run is False

    def test_apply_renames_dir_and_creates_symlink(self) -> None:
        with (
            patch("devdrive_v2.actions.lsof_check", return_value=False),
            patch("devdrive_v2.actions._run") as mock_run,
            patch("devdrive_v2.actions.os.rename") as mock_rename,
            patch("devdrive_v2.actions.os.symlink") as mock_symlink,
        ):
            mock_run.side_effect = [
                _completed(stdout="rsync ok"),
                _completed(stdout=""),
            ]
            fix_real_dir_drift(self._ev(), dry_run=False)

        mock_rename.assert_called_once_with(self._SYSTEM_PATH, f"{self._SYSTEM_PATH}.bak")
        mock_symlink.assert_called_once_with(self._TARGET, self._SYSTEM_PATH)

    def test_apply_rsync_failure_returns_failure(self) -> None:
        with (
            patch("devdrive_v2.actions.lsof_check", return_value=False),
            patch("devdrive_v2.actions._run") as mock_run,
        ):
            mock_run.return_value = _completed(returncode=1, stderr="rsync error")
            result = fix_real_dir_drift(self._ev(), dry_run=False)
        assert result.success is False
        assert "rsync" in result.detail.lower()

    def test_apply_diff_failure_returns_failure(self) -> None:
        with (
            patch("devdrive_v2.actions.lsof_check", return_value=False),
            patch("devdrive_v2.actions._run") as mock_run,
        ):
            mock_run.side_effect = [
                _completed(stdout="rsync ok"),
                _completed(returncode=1, stdout="Files differ"),
            ]
            result = fix_real_dir_drift(self._ev(), dry_run=False)
        assert result.success is False
        assert "verification" in result.detail.lower() or "differ" in result.detail.lower()

    def test_apply_no_target_in_detail_returns_failure(self) -> None:
        ev = _event(
            category=DriftCategory.REAL_DIR_DRIFT,
            source="/tmp/real-dir",
            detail="No path info here.",
        )
        with patch("devdrive_v2.actions.lsof_check", return_value=False):
            result = fix_real_dir_drift(ev, dry_run=False)
        assert result.success is False


# ---------------------------------------------------------------------------
# fix_unmounted_vol
# ---------------------------------------------------------------------------


class TestFixUnmountedVol:
    """Tests for fix_unmounted_vol."""

    _VOL = "DDRV900"
    _DETAIL = f"Volume '{_VOL}' mount_point '/Volumes/DDRV900' is not a mounted directory."

    def _ev(self) -> DriftEvent:
        return _event(
            category=DriftCategory.UNMOUNTED_VOL,
            source=self._VOL,
            detail=self._DETAIL,
        )

    # -- dry-run -------------------------------------------------------------

    def test_dry_run_returns_dry_run_true(self) -> None:
        result = fix_unmounted_vol(self._ev(), dry_run=True)
        assert result.dry_run is True

    def test_dry_run_success_true(self) -> None:
        result = fix_unmounted_vol(self._ev(), dry_run=True)
        assert result.success is True

    def test_dry_run_no_subprocess_call(self) -> None:
        with patch("devdrive_v2.actions._run") as mock_run:
            fix_unmounted_vol(self._ev(), dry_run=True)
            mock_run.assert_not_called()

    def test_dry_run_detail_mentions_diskutil(self) -> None:
        result = fix_unmounted_vol(self._ev(), dry_run=True)
        assert "diskutil" in result.detail

    def test_dry_run_action_name(self) -> None:
        result = fix_unmounted_vol(self._ev(), dry_run=True)
        assert result.action == "fix_unmounted_vol"

    # -- apply mode ----------------------------------------------------------

    def test_apply_calls_diskutil_mount(self) -> None:
        with patch("devdrive_v2.actions._run") as mock_run:
            mock_run.return_value = _completed(stdout="Volume DDRV900 mounted.")
            result = fix_unmounted_vol(self._ev(), dry_run=False)
        mock_run.assert_called_once_with(["diskutil", "mount", self._VOL], timeout=30)
        assert result.success is True
        assert result.dry_run is False

    def test_apply_failure_on_nonzero_return(self) -> None:
        with patch("devdrive_v2.actions._run") as mock_run:
            mock_run.return_value = _completed(returncode=1, stderr="no such volume")
            result = fix_unmounted_vol(self._ev(), dry_run=False)
        assert result.success is False
        assert "no such volume" in result.detail


# ---------------------------------------------------------------------------
# fix_band_bloat
# ---------------------------------------------------------------------------


class TestFixBandBloat:
    """Tests for fix_band_bloat."""

    _VOL = "DDRV902"
    _IMAGE = "/Users/Shared/lfg/images/DDRV902.sparseimage"
    _DETAIL = f"Sparse image for volume '{_VOL}' has 60000 band files."

    def _ev(self) -> DriftEvent:
        return _event(
            category=DriftCategory.BAND_BLOAT,
            source=self._VOL,
            detail=self._DETAIL,
        )

    def _diskutil_run(self) -> Any:
        """Return a _run mock that serves diskutil info and hdiutil compact."""
        diskutil_output = f"   Image Path:               {self._IMAGE}\n   Mounted: Yes\n"

        def _run_fn(args: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
            if args and "diskutil" in args[0]:
                return _completed(stdout=diskutil_output)
            if args and "hdiutil" in args[0]:
                return _completed(stdout="compacted OK")
            return _completed()

        return _run_fn

    # -- dry-run -------------------------------------------------------------

    def test_dry_run_returns_dry_run_true(self) -> None:
        with patch("devdrive_v2.actions._run", side_effect=self._diskutil_run()):
            result = fix_band_bloat(self._ev(), dry_run=True)
        assert result.dry_run is True

    def test_dry_run_success_true(self) -> None:
        with patch("devdrive_v2.actions._run", side_effect=self._diskutil_run()):
            result = fix_band_bloat(self._ev(), dry_run=True)
        assert result.success is True

    def test_dry_run_no_hdiutil_call(self) -> None:
        """diskutil info is called to resolve the path, but hdiutil should not run."""
        calls: list[list[str]] = []

        def _run_fn(args: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
            calls.append(args)
            if "diskutil" in args[0]:
                return _completed(stdout=f"   Image Path:               {self._IMAGE}\n")
            return _completed()

        with patch("devdrive_v2.actions._run", side_effect=_run_fn):
            fix_band_bloat(self._ev(), dry_run=True)

        hdiutil_calls = [c for c in calls if "hdiutil" in c[0]]
        assert len(hdiutil_calls) == 0

    def test_dry_run_detail_mentions_hdiutil_compact(self) -> None:
        with patch("devdrive_v2.actions._run", side_effect=self._diskutil_run()):
            result = fix_band_bloat(self._ev(), dry_run=True)
        assert "hdiutil compact" in result.detail

    def test_dry_run_action_name(self) -> None:
        with patch("devdrive_v2.actions._run", side_effect=self._diskutil_run()):
            result = fix_band_bloat(self._ev(), dry_run=True)
        assert result.action == "fix_band_bloat"

    def test_dry_run_failure_when_image_not_resolvable(self) -> None:
        with patch("devdrive_v2.actions._run") as mock_run:
            mock_run.return_value = _completed(stdout="No image path info.")
            result = fix_band_bloat(self._ev(), dry_run=True)
        assert result.success is False

    # -- apply mode ----------------------------------------------------------

    def test_apply_calls_hdiutil_compact(self) -> None:
        with patch("devdrive_v2.actions._run", side_effect=self._diskutil_run()) as mock_run:
            result = fix_band_bloat(self._ev(), dry_run=False)

        hdiutil_calls = [
            c for c in mock_run.call_args_list if "hdiutil" in c.args[0][0]
        ]
        assert len(hdiutil_calls) == 1
        assert hdiutil_calls[0].args[0] == ["hdiutil", "compact", self._IMAGE]
        assert result.success is True
        assert result.dry_run is False

    def test_apply_failure_on_hdiutil_error(self) -> None:
        def _run_fn(args: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
            if "diskutil" in args[0]:
                return _completed(stdout=f"   Image Path:               {self._IMAGE}\n")
            return _completed(returncode=1, stderr="image is locked")

        with patch("devdrive_v2.actions._run", side_effect=_run_fn):
            result = fix_band_bloat(self._ev(), dry_run=False)

        assert result.success is False
        assert "image is locked" in result.detail


# ---------------------------------------------------------------------------
# fix_snapshot_locked
# ---------------------------------------------------------------------------


class TestFixSnapshotLocked:
    """Tests for fix_snapshot_locked."""

    _DETAIL = "3 local APFS snapshot(s) consuming ~15,000,000,000 bytes."

    def _ev(self) -> DriftEvent:
        return _event(
            category=DriftCategory.SNAPSHOT_LOCKED,
            source="/",
            detail=self._DETAIL,
        )

    # -- dry-run -------------------------------------------------------------

    def test_dry_run_returns_dry_run_true(self) -> None:
        result = fix_snapshot_locked(self._ev(), dry_run=True)
        assert result.dry_run is True

    def test_dry_run_success_true(self) -> None:
        result = fix_snapshot_locked(self._ev(), dry_run=True)
        assert result.success is True

    def test_dry_run_no_subprocess_call(self) -> None:
        with patch("devdrive_v2.actions._run") as mock_run:
            fix_snapshot_locked(self._ev(), dry_run=True)
            mock_run.assert_not_called()

    def test_dry_run_detail_mentions_tmutil(self) -> None:
        result = fix_snapshot_locked(self._ev(), dry_run=True)
        assert "tmutil" in result.detail

    def test_dry_run_action_name(self) -> None:
        result = fix_snapshot_locked(self._ev(), dry_run=True)
        assert result.action == "fix_snapshot_locked"

    def test_dry_run_custom_threshold_reflected_in_detail(self) -> None:
        result = fix_snapshot_locked(self._ev(), dry_run=True, threshold_gb=5)
        assert "5" in result.detail

    # -- apply mode ----------------------------------------------------------

    def test_apply_calls_tmutil_thinlocalsnapshots(self) -> None:
        threshold_gb = 10
        expected_bytes = str(threshold_gb * 1024 ** 3)

        with patch("devdrive_v2.actions._run") as mock_run:
            mock_run.return_value = _completed(stdout="Thinned snapshots.")
            result = fix_snapshot_locked(self._ev(), dry_run=False, threshold_gb=threshold_gb)

        mock_run.assert_called_once_with(
            ["tmutil", "thinlocalsnapshots", "/", expected_bytes],
            timeout=120,
        )
        assert result.success is True
        assert result.dry_run is False

    def test_apply_failure_on_nonzero_return(self) -> None:
        with patch("devdrive_v2.actions._run") as mock_run:
            mock_run.return_value = _completed(returncode=1, stderr="not enough privileges")
            result = fix_snapshot_locked(self._ev(), dry_run=False)
        assert result.success is False
        assert "not enough privileges" in result.detail


# ---------------------------------------------------------------------------
# dispatch_action routing
# ---------------------------------------------------------------------------


class TestDispatchAction:
    """Tests for dispatch_action — verifies routing to correct fix functions."""

    def _ev(self, category: DriftCategory, source: str = "/tmp/x") -> DriftEvent:
        target = "/Volumes/VOL/data"
        detail = f"Symlink '{source}' points to '{target}' but gone."
        return DriftEvent(
            category=category,
            source=source,
            detail=detail,
            severity="warning",
        )

    def test_routes_missing_link(self) -> None:
        ev = self._ev(DriftCategory.MISSING_LINK)
        with patch("devdrive_v2.actions.fix_missing_link") as mock_fn:
            mock_fn.return_value = ActionResult(
                success=True, action="fix_missing_link", source=ev.source,
                detail="ok", dry_run=True
            )
            dispatch_action(ev, dry_run=True)
        mock_fn.assert_called_once_with(ev, dry_run=True)

    def test_routes_stale_target(self) -> None:
        ev = self._ev(DriftCategory.STALE_TARGET)
        with patch("devdrive_v2.actions.fix_stale_target") as mock_fn:
            mock_fn.return_value = ActionResult(
                success=True, action="fix_stale_target", source=ev.source,
                detail="ok", dry_run=True
            )
            dispatch_action(ev, dry_run=True)
        mock_fn.assert_called_once_with(ev, dry_run=True)

    def test_routes_real_dir_drift(self) -> None:
        ev = self._ev(DriftCategory.REAL_DIR_DRIFT)
        with (
            patch("devdrive_v2.actions.fix_real_dir_drift") as mock_fn,
            patch("devdrive_v2.actions.lsof_check", return_value=False),
        ):
            mock_fn.return_value = ActionResult(
                success=True, action="fix_real_dir_drift", source=ev.source,
                detail="ok", dry_run=True
            )
            dispatch_action(ev, dry_run=True)
        mock_fn.assert_called_once_with(ev, dry_run=True)

    def test_routes_unmounted_vol(self) -> None:
        ev = self._ev(DriftCategory.UNMOUNTED_VOL, source="DDRV900")
        with patch("devdrive_v2.actions.fix_unmounted_vol") as mock_fn:
            mock_fn.return_value = ActionResult(
                success=True, action="fix_unmounted_vol", source=ev.source,
                detail="ok", dry_run=True
            )
            dispatch_action(ev, dry_run=True)
        mock_fn.assert_called_once_with(ev, dry_run=True)

    def test_routes_band_bloat(self) -> None:
        ev = self._ev(DriftCategory.BAND_BLOAT, source="DDRV902")
        with patch("devdrive_v2.actions.fix_band_bloat") as mock_fn:
            mock_fn.return_value = ActionResult(
                success=True, action="fix_band_bloat", source=ev.source,
                detail="ok", dry_run=True
            )
            dispatch_action(ev, dry_run=True)
        mock_fn.assert_called_once_with(ev, dry_run=True)

    def test_routes_snapshot_locked(self) -> None:
        ev = self._ev(DriftCategory.SNAPSHOT_LOCKED, source="/")
        with patch("devdrive_v2.actions.fix_snapshot_locked") as mock_fn:
            mock_fn.return_value = ActionResult(
                success=True, action="fix_snapshot_locked", source=ev.source,
                detail="ok", dry_run=True
            )
            dispatch_action(ev, dry_run=True)
        mock_fn.assert_called_once_with(ev, dry_run=True)

    def test_oversized_returns_no_action_available(self) -> None:
        ev = self._ev(DriftCategory.OVERSIZED, source="DDRV901")
        result = dispatch_action(ev, dry_run=True)
        assert result.success is False
        assert "manual" in result.detail.lower() or "no automated" in result.detail.lower()

    def test_swap_pressure_returns_no_action_available(self) -> None:
        ev = self._ev(DriftCategory.SWAP_PRESSURE, source="vm.swapusage")
        result = dispatch_action(ev, dry_run=True)
        assert result.success is False

    def test_dispatch_passes_dry_run_false(self) -> None:
        ev = self._ev(DriftCategory.UNMOUNTED_VOL, source="DDRV900")
        with patch("devdrive_v2.actions.fix_unmounted_vol") as mock_fn:
            mock_fn.return_value = ActionResult(
                success=True, action="fix_unmounted_vol", source=ev.source,
                detail="mounted", dry_run=False
            )
            result = dispatch_action(ev, dry_run=False)
        _, kwargs = mock_fn.call_args
        assert kwargs.get("dry_run") is False

    def test_dispatch_result_carries_through(self) -> None:
        """The ActionResult from the handler is returned verbatim."""
        ev = self._ev(DriftCategory.MISSING_LINK)
        expected = ActionResult(
            success=False, action="fix_missing_link", source=ev.source,
            detail="cannot parse target", dry_run=True
        )
        with patch("devdrive_v2.actions.fix_missing_link", return_value=expected):
            result = dispatch_action(ev, dry_run=True)
        assert result is expected

"""Tests for devdrive_v2.launchagent — LaunchAgent lifecycle management.

Run with:
    PYTHONPATH=lib pytest lib/devdrive_v2/tests/test_launchagent.py -v

All subprocess and filesystem interactions are mocked; no real launchctl
commands or plist files are exercised.
"""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, call, patch

import pytest

import devdrive_v2.launchagent as la
from devdrive_v2.launchagent import (
    AGENT_LABEL,
    LAUNCH_AGENTS_DIR,
    LEGACY_AUTOMOUNT_LABEL,
    PLIST_FILENAME,
    PLIST_SOURCE,
    AgentResult,
    install,
    is_loaded,
    remove_legacy_automount,
    setup_reconcile,
    start,
    stop,
    verify_boot_mount,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _ok(returncode: int = 0, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess:  # type: ignore[type-arg]
    """Return a successful CompletedProcess stub."""
    return subprocess.CompletedProcess(
        args=[], returncode=returncode, stdout=stdout, stderr=stderr
    )


def _fail(returncode: int = 1, stdout: str = "", stderr: str = "error") -> subprocess.CompletedProcess:  # type: ignore[type-arg]
    """Return a failing CompletedProcess stub."""
    return subprocess.CompletedProcess(
        args=[], returncode=returncode, stdout=stdout, stderr=stderr
    )


# The full dotted path used in every patch — targets the module-level _run
# so all callers are affected uniformly.
_RUN_TARGET = "devdrive_v2.launchagent._run"
_COPY2_TARGET = "devdrive_v2.launchagent.shutil.copy2"
_MKDIR_TARGET = "devdrive_v2.launchagent.LAUNCH_AGENTS_DIR"
_GETUID_TARGET = "devdrive_v2.launchagent.os.getuid"


# ---------------------------------------------------------------------------
# AgentResult
# ---------------------------------------------------------------------------


class TestAgentResult:
    """Dataclass field contract."""

    def test_fields_accessible(self) -> None:
        r = AgentResult(success=True, action="install", message="ok")
        assert r.success is True
        assert r.action == "install"
        assert r.message == "ok"

    def test_failure_case(self) -> None:
        r = AgentResult(success=False, action="start", message="boom")
        assert r.success is False

    @pytest.mark.parametrize("action", ["install", "uninstall", "start", "stop", "verify"])
    def test_valid_action_values(self, action: str) -> None:
        r = AgentResult(success=True, action=action, message="")
        assert r.action == action


# ---------------------------------------------------------------------------
# install()
# ---------------------------------------------------------------------------


class TestInstall:
    """install() copies the plist and validates it with plutil -lint."""

    def test_success_copies_plist(self, tmp_path: Path) -> None:
        dest_dir = tmp_path / "LaunchAgents"
        dest_dir.mkdir()
        dest_file = dest_dir / PLIST_FILENAME

        with (
            patch(_COPY2_TARGET) as mock_copy,
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
            patch(_RUN_TARGET, return_value=_ok()),
        ):
            result = install()

        assert result.success is True
        assert result.action == "install"
        mock_copy.assert_called_once_with(str(PLIST_SOURCE), str(dest_dir / PLIST_FILENAME))

    def test_success_runs_plutil_lint(self, tmp_path: Path) -> None:
        dest_dir = tmp_path / "LaunchAgents"
        dest_dir.mkdir()

        with (
            patch(_COPY2_TARGET),
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
            patch(_RUN_TARGET, return_value=_ok()) as mock_run,
        ):
            result = install()

        assert result.success is True
        # Verify plutil -lint was called with the destination plist path.
        args_used = mock_run.call_args[0][0]
        assert args_used[:2] == ["plutil", "-lint"]
        assert str(dest_dir / PLIST_FILENAME) in args_used

    def test_copy_oserror_returns_failure(self, tmp_path: Path) -> None:
        dest_dir = tmp_path / "LaunchAgents"
        dest_dir.mkdir()

        with (
            patch(_COPY2_TARGET, side_effect=OSError("permission denied")),
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
        ):
            result = install()

        assert result.success is False
        assert result.action == "install"
        assert "permission denied" in result.message

    def test_plutil_nonzero_returns_failure(self, tmp_path: Path) -> None:
        dest_dir = tmp_path / "LaunchAgents"
        dest_dir.mkdir()

        with (
            patch(_COPY2_TARGET),
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
            patch(_RUN_TARGET, return_value=_fail(returncode=1, stderr="bad plist")),
        ):
            result = install()

        assert result.success is False
        assert "bad plist" in result.message or "lint failed" in result.message.lower()

    def test_plutil_not_found_returns_success_with_caveat(
        self, tmp_path: Path
    ) -> None:
        """If plutil is absent the copy still succeeded — report success."""
        dest_dir = tmp_path / "LaunchAgents"
        dest_dir.mkdir()

        with (
            patch(_COPY2_TARGET),
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
            patch(_RUN_TARGET, side_effect=FileNotFoundError("no plutil")),
        ):
            result = install()

        assert result.success is True
        assert result.action == "install"

    def test_plutil_timeout_returns_success_with_caveat(
        self, tmp_path: Path
    ) -> None:
        dest_dir = tmp_path / "LaunchAgents"
        dest_dir.mkdir()

        with (
            patch(_COPY2_TARGET),
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
            patch(
                _RUN_TARGET,
                side_effect=subprocess.TimeoutExpired(cmd="plutil", timeout=30),
            ),
        ):
            result = install()

        assert result.success is True

    def test_launch_agents_dir_created_if_missing(self, tmp_path: Path) -> None:
        dest_dir = tmp_path / "LaunchAgents"
        # Deliberately do NOT create dest_dir beforehand.

        with (
            patch(_COPY2_TARGET),
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
            patch(_RUN_TARGET, return_value=_ok()),
        ):
            install()

        assert dest_dir.exists()


# ---------------------------------------------------------------------------
# start()
# ---------------------------------------------------------------------------


class TestStart:
    """start() issues launchctl bootstrap gui/<uid> <plist_path>."""

    def test_success(self, tmp_path: Path) -> None:
        dest_dir = tmp_path / "LaunchAgents"

        with (
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, return_value=_ok()) as mock_run,
        ):
            result = start()

        assert result.success is True
        assert result.action == "start"
        args_used = mock_run.call_args[0][0]
        assert args_used[0] == "launchctl"
        assert args_used[1] == "bootstrap"
        assert args_used[2] == "gui/501"
        assert str(dest_dir / PLIST_FILENAME) in args_used

    def test_failure_nonzero_returncode(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, return_value=_fail(returncode=125, stderr="already loaded")),
        ):
            result = start()

        assert result.success is False
        assert result.action == "start"

    def test_launchctl_not_found(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, side_effect=FileNotFoundError("no launchctl")),
        ):
            result = start()

        assert result.success is False

    def test_timeout(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=501),
            patch(
                _RUN_TARGET,
                side_effect=subprocess.TimeoutExpired(cmd="launchctl", timeout=30),
            ),
        ):
            result = start()

        assert result.success is False

    def test_gui_domain_uses_os_getuid(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=1234),
            patch(_RUN_TARGET, return_value=_ok()) as mock_run,
        ):
            start()

        domain = mock_run.call_args[0][0][2]
        assert domain == "gui/1234"


# ---------------------------------------------------------------------------
# stop()
# ---------------------------------------------------------------------------


class TestStop:
    """stop() issues launchctl bootout gui/<uid>/<label>."""

    def test_success(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, return_value=_ok()) as mock_run,
        ):
            result = stop()

        assert result.success is True
        assert result.action == "stop"
        args_used = mock_run.call_args[0][0]
        assert args_used[0] == "launchctl"
        assert args_used[1] == "bootout"
        assert args_used[2] == f"gui/501/{AGENT_LABEL}"

    def test_failure_nonzero_returncode(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, return_value=_fail(returncode=3, stderr="not loaded")),
        ):
            result = stop()

        assert result.success is False
        assert result.action == "stop"

    def test_launchctl_not_found(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, side_effect=FileNotFoundError()),
        ):
            result = stop()

        assert result.success is False

    def test_timeout(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=501),
            patch(
                _RUN_TARGET,
                side_effect=subprocess.TimeoutExpired(cmd="launchctl", timeout=30),
            ),
        ):
            result = stop()

        assert result.success is False

    def test_service_target_includes_label(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=9999),
            patch(_RUN_TARGET, return_value=_ok()) as mock_run,
        ):
            stop()

        target = mock_run.call_args[0][0][2]
        assert target == f"gui/9999/{AGENT_LABEL}"


# ---------------------------------------------------------------------------
# is_loaded()
# ---------------------------------------------------------------------------


class TestIsLoaded:
    """is_loaded() uses launchctl print gui/<uid>/<label>."""

    def test_returns_true_when_returncode_zero(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, return_value=_ok()),
        ):
            assert is_loaded() is True

    def test_returns_false_when_returncode_nonzero(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, return_value=_fail(returncode=113)),
        ):
            assert is_loaded() is False

    def test_returns_false_on_file_not_found(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, side_effect=FileNotFoundError()),
        ):
            assert is_loaded() is False

    def test_returns_false_on_timeout(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=501),
            patch(
                _RUN_TARGET,
                side_effect=subprocess.TimeoutExpired(cmd="launchctl", timeout=30),
            ),
        ):
            assert is_loaded() is False

    def test_print_command_targets_correct_service(self) -> None:
        with (
            patch(_GETUID_TARGET, return_value=7777),
            patch(_RUN_TARGET, return_value=_ok()) as mock_run,
        ):
            is_loaded()

        args_used = mock_run.call_args[0][0]
        assert args_used == ["launchctl", "print", f"gui/7777/{AGENT_LABEL}"]


# ---------------------------------------------------------------------------
# verify_boot_mount()
# ---------------------------------------------------------------------------


class TestVerifyBootMount:
    """verify_boot_mount() checks each volume name appears in mount output."""

    _MOUNT_OUTPUT = (
        "/dev/disk3s5 on / (apfs, local, read-only)\n"
        "901DEVLIB on /Volumes/901DEVLIB (hfs, local, nodev, nosuid)\n"
        "902DEVENV on /Volumes/902DEVENV (hfs, local, nodev, nosuid)\n"
        "903DEVHOOKS on /Volumes/903DEVHOOKS (hfs, local, nodev, nosuid)\n"
    )

    def test_all_mounted_returns_success(self) -> None:
        volumes = ["901DEVLIB", "902DEVENV", "903DEVHOOKS"]
        with patch(_RUN_TARGET, return_value=_ok(stdout=self._MOUNT_OUTPUT)):
            result = verify_boot_mount(volumes)

        assert result.success is True
        assert result.action == "verify"

    def test_message_mentions_all_volumes_on_success(self) -> None:
        volumes = ["901DEVLIB", "902DEVENV"]
        with patch(_RUN_TARGET, return_value=_ok(stdout=self._MOUNT_OUTPUT)):
            result = verify_boot_mount(volumes)

        for vol in volumes:
            assert vol in result.message

    def test_missing_volume_returns_failure(self) -> None:
        volumes = ["901DEVLIB", "MISSINGVOL"]
        with patch(_RUN_TARGET, return_value=_ok(stdout=self._MOUNT_OUTPUT)):
            result = verify_boot_mount(volumes)

        assert result.success is False
        assert "MISSINGVOL" in result.message

    def test_all_missing_returns_failure(self) -> None:
        with patch(_RUN_TARGET, return_value=_ok(stdout="")):
            result = verify_boot_mount(["VOLA", "VOLB"])

        assert result.success is False
        assert "VOLA" in result.message
        assert "VOLB" in result.message

    def test_empty_list_returns_success(self) -> None:
        with patch(_RUN_TARGET, return_value=_ok(stdout=self._MOUNT_OUTPUT)):
            result = verify_boot_mount([])

        assert result.success is True

    def test_mount_not_found_returns_failure(self) -> None:
        with patch(_RUN_TARGET, side_effect=FileNotFoundError("no mount")):
            result = verify_boot_mount(["901DEVLIB"])

        assert result.success is False
        assert result.action == "verify"

    def test_mount_timeout_returns_failure(self) -> None:
        with patch(
            _RUN_TARGET,
            side_effect=subprocess.TimeoutExpired(cmd="mount", timeout=30),
        ):
            result = verify_boot_mount(["901DEVLIB"])

        assert result.success is False

    def test_partial_mount_only_missing_reported(self) -> None:
        volumes = ["901DEVLIB", "ABSENT1", "902DEVENV", "ABSENT2"]
        with patch(_RUN_TARGET, return_value=_ok(stdout=self._MOUNT_OUTPUT)):
            result = verify_boot_mount(volumes)

        assert result.success is False
        assert "ABSENT1" in result.message
        assert "ABSENT2" in result.message
        # Present volumes should not appear in failure message
        assert "901DEVLIB" not in result.message
        assert "902DEVENV" not in result.message


# ---------------------------------------------------------------------------
# remove_legacy_automount()
# ---------------------------------------------------------------------------


class TestRemoveLegacyAutomount:
    """remove_legacy_automount() stops and removes the legacy plist."""

    def test_plist_not_present_returns_success(self, tmp_path: Path) -> None:
        legacy_dir = tmp_path / "LaunchAgents"
        legacy_dir.mkdir()

        with patch.object(la, "LAUNCH_AGENTS_DIR", legacy_dir):
            result = remove_legacy_automount()

        assert result.success is True
        assert result.action == "uninstall"

    def test_plist_exists_stops_and_removes(self, tmp_path: Path) -> None:
        legacy_dir = tmp_path / "LaunchAgents"
        legacy_dir.mkdir()
        legacy_plist = legacy_dir / f"{LEGACY_AUTOMOUNT_LABEL}.plist"
        legacy_plist.touch()

        with (
            patch.object(la, "LAUNCH_AGENTS_DIR", legacy_dir),
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, return_value=_ok()) as mock_run,
        ):
            result = remove_legacy_automount()

        assert result.success is True
        assert result.action == "uninstall"
        assert not legacy_plist.exists()
        # launchctl bootout was called with the legacy service target
        bootout_call = mock_run.call_args_list[0]
        args_used = bootout_call[0][0]
        assert args_used[0] == "launchctl"
        assert args_used[1] == "bootout"
        assert f"gui/501/{LEGACY_AUTOMOUNT_LABEL}" in args_used[2]

    def test_bootout_failure_still_removes_plist(self, tmp_path: Path) -> None:
        """A non-zero bootout should not prevent plist removal."""
        legacy_dir = tmp_path / "LaunchAgents"
        legacy_dir.mkdir()
        legacy_plist = legacy_dir / f"{LEGACY_AUTOMOUNT_LABEL}.plist"
        legacy_plist.touch()

        with (
            patch.object(la, "LAUNCH_AGENTS_DIR", legacy_dir),
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, return_value=_fail(returncode=3, stderr="not loaded")),
        ):
            result = remove_legacy_automount()

        assert result.success is True
        assert not legacy_plist.exists()

    def test_bootout_exception_still_removes_plist(self, tmp_path: Path) -> None:
        legacy_dir = tmp_path / "LaunchAgents"
        legacy_dir.mkdir()
        legacy_plist = legacy_dir / f"{LEGACY_AUTOMOUNT_LABEL}.plist"
        legacy_plist.touch()

        with (
            patch.object(la, "LAUNCH_AGENTS_DIR", legacy_dir),
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, side_effect=FileNotFoundError()),
        ):
            result = remove_legacy_automount()

        assert result.success is True
        assert not legacy_plist.exists()

    def test_unlink_oserror_returns_failure(self, tmp_path: Path) -> None:
        legacy_dir = tmp_path / "LaunchAgents"
        legacy_dir.mkdir()
        legacy_plist = legacy_dir / f"{LEGACY_AUTOMOUNT_LABEL}.plist"
        legacy_plist.touch()

        with (
            patch.object(la, "LAUNCH_AGENTS_DIR", legacy_dir),
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, return_value=_ok()),
            patch.object(Path, "unlink", side_effect=OSError("locked")),
        ):
            result = remove_legacy_automount()

        assert result.success is False
        assert "locked" in result.message

    def test_label_in_message(self, tmp_path: Path) -> None:
        legacy_dir = tmp_path / "LaunchAgents"
        legacy_dir.mkdir()
        legacy_plist = legacy_dir / f"{LEGACY_AUTOMOUNT_LABEL}.plist"
        legacy_plist.touch()

        with (
            patch.object(la, "LAUNCH_AGENTS_DIR", legacy_dir),
            patch(_GETUID_TARGET, return_value=501),
            patch(_RUN_TARGET, return_value=_ok()),
        ):
            result = remove_legacy_automount()

        assert LEGACY_AUTOMOUNT_LABEL in result.message


# ---------------------------------------------------------------------------
# setup_reconcile()
# ---------------------------------------------------------------------------


class TestSetupReconcile:
    """setup_reconcile() orchestrates install → start → verify."""

    def _patch_install(self, success: bool, message: str = "") -> Any:
        return patch(
            "devdrive_v2.launchagent.install",
            return_value=AgentResult(
                success=success,
                action="install",
                message=message or ("ok" if success else "fail"),
            ),
        )

    def _patch_start(self, success: bool, message: str = "") -> Any:
        return patch(
            "devdrive_v2.launchagent.start",
            return_value=AgentResult(
                success=success,
                action="start",
                message=message or ("ok" if success else "fail"),
            ),
        )

    def test_full_success(self, tmp_path: Path) -> None:
        dest_dir = tmp_path / "LaunchAgents"
        dest_dir.mkdir()

        with (
            self._patch_install(True),
            self._patch_start(True),
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
            patch(_RUN_TARGET, return_value=_ok()),
        ):
            result = setup_reconcile()

        assert result.success is True
        assert result.action == "verify"

    def test_install_failure_returns_early(self) -> None:
        with (
            self._patch_install(False, "copy error"),
            patch("devdrive_v2.launchagent.start") as mock_start,
        ):
            result = setup_reconcile()

        assert result.success is False
        assert result.action == "install"
        assert "copy error" in result.message
        mock_start.assert_not_called()

    def test_start_failure_returns_early(self, tmp_path: Path) -> None:
        dest_dir = tmp_path / "LaunchAgents"
        dest_dir.mkdir()

        with (
            self._patch_install(True),
            self._patch_start(False, "already loaded"),
        ):
            result = setup_reconcile()

        assert result.success is False
        assert result.action == "start"
        assert "already loaded" in result.message

    def test_plutil_verify_failure_returns_failure(self, tmp_path: Path) -> None:
        dest_dir = tmp_path / "LaunchAgents"
        dest_dir.mkdir()

        with (
            self._patch_install(True),
            self._patch_start(True),
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
            patch(_RUN_TARGET, return_value=_fail(returncode=1, stderr="malformed")),
        ):
            result = setup_reconcile()

        assert result.success is False
        assert result.action == "verify"

    def test_plutil_not_found_returns_success_with_caveat(
        self, tmp_path: Path
    ) -> None:
        dest_dir = tmp_path / "LaunchAgents"
        dest_dir.mkdir()

        with (
            self._patch_install(True),
            self._patch_start(True),
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
            patch(_RUN_TARGET, side_effect=FileNotFoundError()),
        ):
            result = setup_reconcile()

        assert result.success is True
        assert result.action == "verify"

    def test_plutil_timeout_returns_success_with_caveat(
        self, tmp_path: Path
    ) -> None:
        dest_dir = tmp_path / "LaunchAgents"
        dest_dir.mkdir()

        with (
            self._patch_install(True),
            self._patch_start(True),
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
            patch(
                _RUN_TARGET,
                side_effect=subprocess.TimeoutExpired(cmd="plutil", timeout=30),
            ),
        ):
            result = setup_reconcile()

        assert result.success is True
        assert result.action == "verify"

    def test_success_message_contains_agent_label(self, tmp_path: Path) -> None:
        dest_dir = tmp_path / "LaunchAgents"
        dest_dir.mkdir()

        with (
            self._patch_install(True),
            self._patch_start(True),
            patch.object(la, "LAUNCH_AGENTS_DIR", dest_dir),
            patch(_RUN_TARGET, return_value=_ok()),
        ):
            result = setup_reconcile()

        assert AGENT_LABEL in result.message

    def test_install_called_before_start(self) -> None:
        """install must be invoked before start in the orchestration order."""
        call_order: list[str] = []

        def _fake_install() -> AgentResult:
            call_order.append("install")
            return AgentResult(success=True, action="install", message="")

        def _fake_start() -> AgentResult:
            call_order.append("start")
            return AgentResult(success=True, action="start", message="")

        with (
            patch("devdrive_v2.launchagent.install", side_effect=_fake_install),
            patch("devdrive_v2.launchagent.start", side_effect=_fake_start),
            patch(_RUN_TARGET, return_value=_ok()),
        ):
            setup_reconcile()

        assert call_order[0] == "install"
        assert call_order[1] == "start"

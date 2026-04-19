"""Tests for devdrive_v2.claude_integration — Claude Code symlink integration (US-010).

Run with:
    PYTHONPATH=lib pytest lib/devdrive_v2/tests/test_claude_integration.py -v

All filesystem interactions are mocked; no real directories, symlinks, or
subprocess calls are executed during the test suite.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, call, patch

import pytest

from devdrive_v2.claude_integration import (
    ClaudeCodePaths,
    check_symlink_health,
    discover_claude_dirs,
    full_health_check,
    migrate_symlinks,
    register_forest_entries,
    verify_mkdir_p,
)
from devdrive_v2.state import ForestEntry, ForestEntryKind, StateManager


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _make_state_mgr(tmp_path: Path) -> StateManager:
    """Return a freshly loaded StateManager backed by a temp file."""
    mgr = StateManager(path=tmp_path / "devdrive_state.json")
    mgr.load()
    return mgr


def _make_paths(root: Path) -> ClaudeCodePaths:
    """Build a ClaudeCodePaths rooted under *root*."""
    return ClaudeCodePaths(
        claude_dir=root,
        projects_dir=root / "projects",
        tasks_dir=root / "tasks",
    )


# ---------------------------------------------------------------------------
# discover_claude_dirs
# ---------------------------------------------------------------------------


class TestDiscoverClaudeDirs:
    """Tests for discover_claude_dirs()."""

    def test_default_paths_derive_from_home(self) -> None:
        """Without an override, all paths derive from ~/.claude."""
        result = discover_claude_dirs()

        home = Path.home()
        assert result.claude_dir == home / ".claude"
        assert result.projects_dir == home / ".claude" / "projects"
        assert result.tasks_dir == home / ".claude" / "tasks"

    def test_custom_root_propagates_to_sub_paths(self, tmp_path: Path) -> None:
        """Providing a custom root rewires projects and tasks accordingly."""
        custom = tmp_path / "my-claude"
        result = discover_claude_dirs(claude_dir=custom)

        assert result.claude_dir == custom
        assert result.projects_dir == custom / "projects"
        assert result.tasks_dir == custom / "tasks"

    def test_returns_claude_code_paths_instance(self) -> None:
        """Return type is always ClaudeCodePaths."""
        result = discover_claude_dirs()
        assert isinstance(result, ClaudeCodePaths)

    def test_custom_root_none_uses_default(self) -> None:
        """Passing None explicitly is equivalent to omitting the argument."""
        r1 = discover_claude_dirs(None)
        r2 = discover_claude_dirs()
        assert r1.claude_dir == r2.claude_dir
        assert r1.projects_dir == r2.projects_dir
        assert r1.tasks_dir == r2.tasks_dir


# ---------------------------------------------------------------------------
# check_symlink_health
# ---------------------------------------------------------------------------


class TestCheckSymlinkHealth:
    """Tests for check_symlink_health()."""

    def test_returns_two_entries(self, tmp_path: Path) -> None:
        """Always returns one dict per tracked directory (projects + tasks)."""
        paths = _make_paths(tmp_path)
        with (
            patch("os.path.islink", return_value=False),
            patch("os.path.exists", return_value=False),
            patch("os.makedirs", side_effect=OSError("not writable")),
        ):
            results = check_symlink_health(paths)

        assert len(results) == 2

    def test_symlink_exists_and_target_exists(self, tmp_path: Path) -> None:
        """Healthy symlink: is_symlink=True, target_exists=True, writable=True."""
        paths = _make_paths(tmp_path)
        target = str(tmp_path / "volume" / "projects")

        def fake_islink(p: str) -> bool:
            return p in (str(paths.projects_dir), str(paths.tasks_dir))

        def fake_readlink(p: str) -> str:
            return target

        def fake_exists(p: str) -> bool:
            return True

        with (
            patch("os.path.islink", side_effect=fake_islink),
            patch("os.readlink", side_effect=fake_readlink),
            patch("os.path.exists", side_effect=fake_exists),
            patch("os.makedirs"),
            patch("os.rmdir"),
        ):
            results = check_symlink_health(paths)

        projects = results[0]
        assert projects["is_symlink"] is True
        assert projects["target"] == target
        assert projects["target_exists"] is True
        assert projects["writable"] is True

    def test_symlink_exists_but_target_missing(self, tmp_path: Path) -> None:
        """Stale symlink: is_symlink=True, target_exists=False, writable=False."""
        paths = _make_paths(tmp_path)
        stale_target = "/Volumes/MISSING/projects"

        def fake_islink(p: str) -> bool:
            return True

        def fake_readlink(p: str) -> str:
            return stale_target

        def fake_exists(p: str) -> bool:
            # The symlink itself does not resolve (target is gone).
            return False

        with (
            patch("os.path.islink", side_effect=fake_islink),
            patch("os.readlink", side_effect=fake_readlink),
            patch("os.path.exists", side_effect=fake_exists),
            patch("os.makedirs", side_effect=OSError("no such file")),
        ):
            results = check_symlink_health(paths)

        for entry in results:
            assert entry["is_symlink"] is True
            assert entry["target_exists"] is False
            assert entry["writable"] is False

    def test_not_a_symlink_real_dir_writable(self, tmp_path: Path) -> None:
        """Real directory (no symlink): is_symlink=False, target=None."""
        paths = _make_paths(tmp_path)

        def fake_islink(p: str) -> bool:
            return False

        def fake_exists(p: str) -> bool:
            return True

        with (
            patch("os.path.islink", side_effect=fake_islink),
            patch("os.path.exists", side_effect=fake_exists),
            patch("os.makedirs"),
            patch("os.rmdir"),
        ):
            results = check_symlink_health(paths)

        for entry in results:
            assert entry["is_symlink"] is False
            assert entry["target"] is None
            assert entry["target_exists"] is True
            assert entry["writable"] is True

    def test_readlink_error_yields_none_target(self, tmp_path: Path) -> None:
        """When os.readlink raises, target is None and writable is False."""
        paths = _make_paths(tmp_path)

        with (
            patch("os.path.islink", return_value=True),
            patch("os.readlink", side_effect=OSError("bad link")),
            patch("os.path.exists", return_value=True),
            patch("os.makedirs", side_effect=OSError("probe failed")),
        ):
            results = check_symlink_health(paths)

        for entry in results:
            assert entry["target"] is None

    def test_path_strings_match_paths_object(self, tmp_path: Path) -> None:
        """The 'path' key in each result matches the ClaudeCodePaths attributes."""
        paths = _make_paths(tmp_path)

        with (
            patch("os.path.islink", return_value=False),
            patch("os.path.exists", return_value=False),
            patch("os.makedirs", side_effect=OSError),
        ):
            results = check_symlink_health(paths)

        assert results[0]["path"] == str(paths.projects_dir)
        assert results[1]["path"] == str(paths.tasks_dir)


# ---------------------------------------------------------------------------
# register_forest_entries
# ---------------------------------------------------------------------------


class TestRegisterForestEntries:
    """Tests for register_forest_entries()."""

    def test_returns_two_entries(self, tmp_path: Path) -> None:
        """Always returns two ForestEntry objects."""
        mgr = _make_state_mgr(tmp_path)
        paths = _make_paths(tmp_path / "claude")

        entries = register_forest_entries(paths, "DDRV-904-MEMVT", mgr)
        assert len(entries) == 2

    def test_entries_have_auto_repair_true(self, tmp_path: Path) -> None:
        """Both registered entries must have auto_repair=True."""
        mgr = _make_state_mgr(tmp_path)
        paths = _make_paths(tmp_path / "claude")

        entries = register_forest_entries(paths, "DDRV-904-MEMVT", mgr)
        for entry in entries:
            assert entry.auto_repair is True

    def test_entries_expected_kind_is_symlink(self, tmp_path: Path) -> None:
        """expected_kind must be SYMLINK for both entries."""
        mgr = _make_state_mgr(tmp_path)
        paths = _make_paths(tmp_path / "claude")

        entries = register_forest_entries(paths, "DDRV-904-MEMVT", mgr)
        for entry in entries:
            assert entry.expected_kind == ForestEntryKind.SYMLINK.value

    def test_target_paths_include_volume_name(self, tmp_path: Path) -> None:
        """Each entry's target should embed the volume name."""
        mgr = _make_state_mgr(tmp_path)
        paths = _make_paths(tmp_path / "claude")
        vol = "DDRV-904-MEMVT"

        entries = register_forest_entries(paths, vol, mgr)
        for entry in entries:
            assert vol in entry.target

    def test_projects_target_ends_with_projects(self, tmp_path: Path) -> None:
        """The projects entry target should end with 'projects'."""
        mgr = _make_state_mgr(tmp_path)
        paths = _make_paths(tmp_path / "claude")

        entries = register_forest_entries(paths, "DDRV-904-MEMVT", mgr)
        projects_entry = next(e for e in entries if e.id == "claude-code-projects")
        assert projects_entry.target.endswith("/projects")

    def test_tasks_target_ends_with_tasks(self, tmp_path: Path) -> None:
        """The tasks entry target should end with 'tasks'."""
        mgr = _make_state_mgr(tmp_path)
        paths = _make_paths(tmp_path / "claude")

        entries = register_forest_entries(paths, "DDRV-904-MEMVT", mgr)
        tasks_entry = next(e for e in entries if e.id == "claude-code-tasks")
        assert tasks_entry.target.endswith("/tasks")

    def test_entries_persisted_in_state(self, tmp_path: Path) -> None:
        """After register, state_mgr.find_forest_entry should locate both IDs."""
        mgr = _make_state_mgr(tmp_path)
        paths = _make_paths(tmp_path / "claude")

        register_forest_entries(paths, "DDRV-904-MEMVT", mgr)

        assert mgr.find_forest_entry("claude-code-projects") is not None
        assert mgr.find_forest_entry("claude-code-tasks") is not None

    def test_state_saved_to_disk(self, tmp_path: Path) -> None:
        """After register, the state JSON file should exist on disk."""
        state_path = tmp_path / "devdrive_state.json"
        mgr = StateManager(path=state_path)
        mgr.load()
        paths = _make_paths(tmp_path / "claude")

        register_forest_entries(paths, "DDRV-904-MEMVT", mgr)

        assert state_path.exists()

    def test_re_registration_replaces_existing_entry(self, tmp_path: Path) -> None:
        """Calling register twice with a different volume updates the entry."""
        mgr = _make_state_mgr(tmp_path)
        paths = _make_paths(tmp_path / "claude")

        register_forest_entries(paths, "VOL-OLD", mgr)
        register_forest_entries(paths, "VOL-NEW", mgr)

        entry = mgr.find_forest_entry("claude-code-projects")
        assert entry is not None
        assert "VOL-NEW" in entry.target
        assert "VOL-OLD" not in entry.target


# ---------------------------------------------------------------------------
# verify_mkdir_p
# ---------------------------------------------------------------------------


class TestVerifyMkdirP:
    """Tests for verify_mkdir_p()."""

    def test_success_with_default_dirs(self, tmp_path: Path) -> None:
        """With default test dirs and a writable base, success should be True."""
        result = verify_mkdir_p(tmp_path)

        assert result["success"] is True
        assert result["tested"] == 1
        assert result["failed"] == []
        assert result["errors"] == []

    def test_success_with_custom_dirs(self, tmp_path: Path) -> None:
        """Custom multi-level paths should all succeed in a writable temp dir."""
        dirs = ["a/b/c", "d/e"]
        result = verify_mkdir_p(tmp_path, test_dirs=dirs)

        assert result["success"] is True
        assert result["tested"] == 2
        assert result["failed"] == []

    def test_permission_error_reported_in_failed(self, tmp_path: Path) -> None:
        """An OSError during makedirs adds the path to 'failed' and 'errors'."""
        dirs = ["restricted/nested"]

        with patch("os.makedirs", side_effect=OSError("Permission denied")):
            result = verify_mkdir_p(tmp_path, test_dirs=dirs)

        assert result["success"] is False
        assert result["tested"] == 1
        assert "restricted/nested" in result["failed"]
        assert len(result["errors"]) == 1
        assert "Permission denied" in result["errors"][0]

    def test_partial_failure_reported_correctly(self, tmp_path: Path) -> None:
        """When one of two dirs fails, success=False and only that dir is listed."""
        dirs = ["ok/path", "bad/path"]
        call_count = 0

        def selective_makedirs(path: str, exist_ok: bool = False) -> None:
            nonlocal call_count
            call_count += 1
            if "bad" in path:
                raise OSError("Permission denied")

        with (
            patch("os.makedirs", side_effect=selective_makedirs),
            patch("os.rmdir"),  # cleanup for the successful path
        ):
            result = verify_mkdir_p(tmp_path, test_dirs=dirs)

        assert result["success"] is False
        assert result["tested"] == 2
        assert "bad/path" in result["failed"]
        assert "ok/path" not in result["failed"]

    def test_probe_dirs_are_cleaned_up_on_success(self, tmp_path: Path) -> None:
        """After a successful probe, the created directory should not remain."""
        result = verify_mkdir_p(tmp_path)
        assert result["success"] is True
        # The probe directory should have been removed.
        probe = tmp_path / "test-verify" / "nested" / "dir"
        assert not probe.exists()

    def test_empty_test_dirs_returns_zero_tested(self, tmp_path: Path) -> None:
        """Passing an empty list results in tested=0 and success=True."""
        result = verify_mkdir_p(tmp_path, test_dirs=[])

        assert result["success"] is True
        assert result["tested"] == 0
        assert result["failed"] == []


# ---------------------------------------------------------------------------
# migrate_symlinks
# ---------------------------------------------------------------------------


class TestMigrateSymlinks:
    """Tests for migrate_symlinks()."""

    def test_already_correct_symlink_is_skipped(self, tmp_path: Path) -> None:
        """When a symlink already points to the expected target, status='skipped'."""
        paths = _make_paths(tmp_path / "claude")
        vol = "DDRV-904-MEMVT"
        expected_projects = f"/Volumes/{vol}/projects"
        expected_tasks = f"/Volumes/{vol}/tasks"

        def fake_islink(p: str) -> bool:
            return True

        def fake_readlink(p: str) -> str:
            if "projects" in p:
                return expected_projects
            return expected_tasks

        def fake_isdir(p: str) -> bool:
            return False

        with (
            patch("os.path.islink", side_effect=fake_islink),
            patch("os.readlink", side_effect=fake_readlink),
            patch("os.path.isdir", side_effect=fake_isdir),
        ):
            results = migrate_symlinks(paths, vol)

        for r in results:
            assert r["status"] == "skipped"

    def test_symlink_pointing_elsewhere_is_updated(self, tmp_path: Path) -> None:
        """A symlink pointing to the wrong target gets updated."""
        paths = _make_paths(tmp_path / "claude")
        vol = "DDRV-904-MEMVT"

        def fake_islink(p: str) -> bool:
            return True

        def fake_readlink(p: str) -> str:
            # Points to an old volume.
            return "/Volumes/OLD-VOL/projects" if "projects" in p else "/Volumes/OLD-VOL/tasks"

        unlink_calls: list[str] = []
        symlink_calls: list[tuple[str, str]] = []

        def fake_unlink(p: str) -> None:
            unlink_calls.append(p)

        def fake_symlink(src: str, dst: str) -> None:
            symlink_calls.append((src, dst))

        def fake_isdir(p: str) -> bool:
            return False

        with (
            patch("os.path.islink", side_effect=fake_islink),
            patch("os.readlink", side_effect=fake_readlink),
            patch("os.path.isdir", side_effect=fake_isdir),
            patch("os.unlink", side_effect=fake_unlink),
            patch("os.symlink", side_effect=fake_symlink),
        ):
            results = migrate_symlinks(paths, vol)

        for r in results:
            assert r["status"] == "updated"
        assert len(unlink_calls) == 2
        assert len(symlink_calls) == 2

    def test_real_directory_is_skipped_with_warning(self, tmp_path: Path) -> None:
        """A real (non-symlink) directory is left untouched; status='skipped_real_dir'."""
        paths = _make_paths(tmp_path / "claude")
        vol = "DDRV-904-MEMVT"

        def fake_islink(p: str) -> bool:
            return False

        def fake_isdir(p: str) -> bool:
            return True

        with (
            patch("os.path.islink", side_effect=fake_islink),
            patch("os.path.isdir", side_effect=fake_isdir),
        ):
            results = migrate_symlinks(paths, vol)

        for r in results:
            assert r["status"] == "skipped_real_dir"
            assert "real directory" in r["detail"]

    def test_absent_path_creates_new_symlink(self, tmp_path: Path) -> None:
        """When the path does not exist at all, a new symlink is created."""
        paths = _make_paths(tmp_path / "claude")
        vol = "DDRV-904-MEMVT"

        symlink_calls: list[tuple[str, str]] = []

        def fake_symlink(src: str, dst: str) -> None:
            symlink_calls.append((src, dst))

        def fake_islink(p: str) -> bool:
            return False

        def fake_isdir(p: str) -> bool:
            return False

        with (
            patch("os.path.islink", side_effect=fake_islink),
            patch("os.path.isdir", side_effect=fake_isdir),
            patch("os.makedirs"),
            patch("os.symlink", side_effect=fake_symlink),
        ):
            results = migrate_symlinks(paths, vol)

        for r in results:
            assert r["status"] == "created"
        assert len(symlink_calls) == 2

    def test_os_error_on_update_sets_status_error(self, tmp_path: Path) -> None:
        """An OSError during symlink update results in status='error'."""
        paths = _make_paths(tmp_path / "claude")
        vol = "DDRV-904-MEMVT"

        def fake_islink(p: str) -> bool:
            return True

        def fake_readlink(p: str) -> str:
            return "/Volumes/OLD/projects"

        def fake_isdir(p: str) -> bool:
            return False

        with (
            patch("os.path.islink", side_effect=fake_islink),
            patch("os.readlink", side_effect=fake_readlink),
            patch("os.path.isdir", side_effect=fake_isdir),
            patch("os.unlink", side_effect=OSError("permission denied")),
        ):
            results = migrate_symlinks(paths, vol)

        for r in results:
            assert r["status"] == "error"
            assert "permission denied" in r["detail"].lower()

    def test_target_includes_volume_name_and_dir_name(self, tmp_path: Path) -> None:
        """The 'target' field in each result reflects the correct volume path."""
        paths = _make_paths(tmp_path / "claude")
        vol = "MY-VOL"

        def fake_islink(p: str) -> bool:
            return True

        def fake_readlink(p: str) -> str:
            # Already correct.
            if "projects" in p:
                return f"/Volumes/{vol}/projects"
            return f"/Volumes/{vol}/tasks"

        def fake_isdir(p: str) -> bool:
            return False

        with (
            patch("os.path.islink", side_effect=fake_islink),
            patch("os.readlink", side_effect=fake_readlink),
            patch("os.path.isdir", side_effect=fake_isdir),
        ):
            results = migrate_symlinks(paths, vol)

        targets = {r["target"] for r in results}
        assert f"/Volumes/{vol}/projects" in targets
        assert f"/Volumes/{vol}/tasks" in targets

    def test_custom_volumes_root_is_respected(self, tmp_path: Path) -> None:
        """Providing a custom volumes_root changes the target prefix."""
        paths = _make_paths(tmp_path / "claude")
        vol = "DDRV-904-MEMVT"
        custom_root = "/private/Volumes"

        def fake_islink(p: str) -> bool:
            return True

        def fake_readlink(p: str) -> str:
            if "projects" in p:
                return f"{custom_root}/{vol}/projects"
            return f"{custom_root}/{vol}/tasks"

        def fake_isdir(p: str) -> bool:
            return False

        with (
            patch("os.path.islink", side_effect=fake_islink),
            patch("os.readlink", side_effect=fake_readlink),
            patch("os.path.isdir", side_effect=fake_isdir),
        ):
            results = migrate_symlinks(paths, vol, volumes_root=custom_root)

        for r in results:
            assert r["status"] == "skipped"
            assert r["target"].startswith(custom_root)


# ---------------------------------------------------------------------------
# full_health_check
# ---------------------------------------------------------------------------


class TestFullHealthCheck:
    """Tests for full_health_check() orchestration."""

    def test_returns_required_top_level_keys(self, tmp_path: Path) -> None:
        """The report dict must include all documented top-level keys."""
        with (
            patch("os.path.islink", return_value=False),
            patch("os.path.exists", return_value=False),
            patch("os.makedirs", side_effect=OSError("no dir")),
        ):
            report = full_health_check(claude_dir=tmp_path)

        required_keys = {
            "claude_dir",
            "projects_dir",
            "tasks_dir",
            "symlink_health",
            "mkdir_probes",
            "forest_registration",
            "overall_healthy",
        }
        assert required_keys.issubset(report.keys())

    def test_claude_dir_reflects_override(self, tmp_path: Path) -> None:
        """claude_dir in the report should match the override argument."""
        with (
            patch("os.path.islink", return_value=False),
            patch("os.path.exists", return_value=False),
            patch("os.makedirs", side_effect=OSError),
        ):
            report = full_health_check(claude_dir=tmp_path)

        assert report["claude_dir"] == str(tmp_path)

    def test_overall_healthy_false_when_target_missing(self, tmp_path: Path) -> None:
        """overall_healthy is False when any directory's target is missing."""
        with (
            patch("os.path.islink", return_value=True),
            patch("os.readlink", return_value="/Volumes/MISSING/projects"),
            patch("os.path.exists", return_value=False),
            patch("os.makedirs", side_effect=OSError("no mount")),
        ):
            report = full_health_check(claude_dir=tmp_path)

        assert report["overall_healthy"] is False

    def test_overall_healthy_true_when_all_pass(self, tmp_path: Path) -> None:
        """overall_healthy is True when all symlinks resolve and probes succeed."""
        with (
            patch("os.path.islink", return_value=True),
            patch("os.readlink", return_value=str(tmp_path)),
            patch("os.path.exists", return_value=True),
            patch("os.makedirs"),
            patch("os.rmdir"),
        ):
            report = full_health_check(claude_dir=tmp_path)

        assert report["overall_healthy"] is True

    def test_forest_registration_none_without_state_mgr(self, tmp_path: Path) -> None:
        """When no state_mgr is provided, forest_registration should be None."""
        with (
            patch("os.path.islink", return_value=False),
            patch("os.path.exists", return_value=False),
            patch("os.makedirs", side_effect=OSError),
        ):
            report = full_health_check(claude_dir=tmp_path)

        assert report["forest_registration"] is None

    def test_forest_registration_included_with_state_mgr(self, tmp_path: Path) -> None:
        """When state_mgr is provided, forest_registration contains both keys."""
        mgr = _make_state_mgr(tmp_path)

        with (
            patch("os.path.islink", return_value=False),
            patch("os.path.exists", return_value=False),
            patch("os.makedirs", side_effect=OSError),
        ):
            report = full_health_check(claude_dir=tmp_path, state_mgr=mgr)

        fr = report["forest_registration"]
        assert fr is not None
        assert "projects" in fr
        assert "tasks" in fr

    def test_forest_registration_shows_registered_true_after_register(
        self, tmp_path: Path
    ) -> None:
        """Entries registered beforehand appear as registered=True in the report."""
        mgr = _make_state_mgr(tmp_path)
        custom_root = tmp_path / "claude"
        paths = ClaudeCodePaths(
            claude_dir=custom_root,
            projects_dir=custom_root / "projects",
            tasks_dir=custom_root / "tasks",
        )
        register_forest_entries(paths, "DDRV-904-MEMVT", mgr)

        with (
            patch("os.path.islink", return_value=False),
            patch("os.path.exists", return_value=False),
            patch("os.makedirs", side_effect=OSError),
        ):
            report = full_health_check(claude_dir=custom_root, state_mgr=mgr)

        fr = report["forest_registration"]
        assert fr is not None
        assert fr["projects"]["registered"] is True
        assert fr["tasks"]["registered"] is True

    def test_symlink_health_has_two_entries(self, tmp_path: Path) -> None:
        """symlink_health always contains exactly two dicts."""
        with (
            patch("os.path.islink", return_value=False),
            patch("os.path.exists", return_value=False),
            patch("os.makedirs", side_effect=OSError),
        ):
            report = full_health_check(claude_dir=tmp_path)

        assert len(report["symlink_health"]) == 2

    def test_mkdir_probes_has_two_entries(self, tmp_path: Path) -> None:
        """mkdir_probes always contains exactly two dicts."""
        with (
            patch("os.path.islink", return_value=False),
            patch("os.path.exists", return_value=False),
            patch("os.makedirs", side_effect=OSError),
        ):
            report = full_health_check(claude_dir=tmp_path)

        assert len(report["mkdir_probes"]) == 2

    def test_mkdir_probes_skipped_when_target_unreachable(self, tmp_path: Path) -> None:
        """When target_exists is False the mkdir probe is skipped, not attempted."""
        makedirs_calls: list[str] = []

        def tracking_makedirs(path: str, exist_ok: bool = False) -> None:
            makedirs_calls.append(path)
            raise OSError("unreachable")

        with (
            patch("os.path.islink", return_value=False),
            patch("os.path.exists", return_value=False),
            patch("os.makedirs", side_effect=tracking_makedirs),
        ):
            report = full_health_check(claude_dir=tmp_path)

        for probe in report["mkdir_probes"]:
            assert probe["tested"] == 0

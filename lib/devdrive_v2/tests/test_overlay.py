"""Tests for devdrive_v2.overlay — route resolution, config validation, and benchmarks.

All tests are designed to pass WITHOUT macFUSE or fusepy installed.  The import-guard
behaviour and FUSE operation error paths are verified via monkeypatching.
"""

from __future__ import annotations

import errno
import importlib
import os
import sys
import types
from pathlib import Path
from typing import Generator
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Fixtures & helpers
# ---------------------------------------------------------------------------


@pytest.fixture()
def basic_config():
    """Return an OverlayConfig with three routing rules for use across tests."""
    from devdrive_v2.overlay import OverlayConfig

    return OverlayConfig(
        mount_point="/mnt/devdrive",
        route_rules=[
            {"prefix": "/projects", "volume": "DDRV904", "target_subpath": "projects"},
            {"prefix": "/hooks",    "volume": "DDRV900", "target_subpath": "hooks"},
            {"prefix": "/cache",    "volume": "DDRV901", "target_subpath": ""},
        ],
        default_volume="DDRV904",
        volumes_root="/Volumes",
    )


@pytest.fixture()
def overlay(basic_config):
    """Return an OverlayFS instance using the basic_config fixture."""
    from devdrive_v2.overlay import OverlayFS

    return OverlayFS(basic_config)


# ---------------------------------------------------------------------------
# OverlayConfig — creation and validation
# ---------------------------------------------------------------------------


class TestOverlayConfig:
    def test_basic_creation(self, basic_config) -> None:
        assert basic_config.mount_point == "/mnt/devdrive"
        assert len(basic_config.route_rules) == 3
        assert basic_config.default_volume == "DDRV904"
        assert basic_config.volumes_root == "/Volumes"

    def test_empty_mount_point_raises(self) -> None:
        from devdrive_v2.overlay import OverlayConfig

        with pytest.raises(ValueError, match="mount_point must not be empty"):
            OverlayConfig(mount_point="", route_rules=[])

    def test_missing_prefix_key_raises(self) -> None:
        from devdrive_v2.overlay import OverlayConfig

        with pytest.raises(ValueError, match="missing required key 'prefix'"):
            OverlayConfig(
                mount_point="/mnt/x",
                route_rules=[{"volume": "DDRV900", "target_subpath": ""}],
            )

    def test_missing_volume_key_raises(self) -> None:
        from devdrive_v2.overlay import OverlayConfig

        with pytest.raises(ValueError, match="missing required key 'volume'"):
            OverlayConfig(
                mount_point="/mnt/x",
                route_rules=[{"prefix": "/foo", "target_subpath": ""}],
            )

    def test_missing_target_subpath_key_raises(self) -> None:
        from devdrive_v2.overlay import OverlayConfig

        with pytest.raises(ValueError, match="missing required key 'target_subpath'"):
            OverlayConfig(
                mount_point="/mnt/x",
                route_rules=[{"prefix": "/foo", "volume": "DDRV900"}],
            )

    def test_prefix_without_leading_slash_raises(self) -> None:
        from devdrive_v2.overlay import OverlayConfig

        with pytest.raises(ValueError, match="must start with '/'"):
            OverlayConfig(
                mount_point="/mnt/x",
                route_rules=[{"prefix": "no-slash", "volume": "DDRV900", "target_subpath": ""}],
            )

    def test_no_rules_is_valid(self) -> None:
        from devdrive_v2.overlay import OverlayConfig

        cfg = OverlayConfig(mount_point="/mnt/x", route_rules=[], default_volume="DDRV900")
        assert cfg.route_rules == []

    def test_volume_root_helper(self, basic_config) -> None:
        assert basic_config.volume_root("DDRV904") == "/Volumes/DDRV904"
        assert basic_config.volume_root("DDRV901") == "/Volumes/DDRV901"

    def test_custom_volumes_root(self) -> None:
        from devdrive_v2.overlay import OverlayConfig

        cfg = OverlayConfig(
            mount_point="/mnt/x",
            route_rules=[],
            volumes_root="/private/var/volumes",
        )
        assert cfg.volume_root("DDRV900") == "/private/var/volumes/DDRV900"

    def test_default_volumes_root(self) -> None:
        from devdrive_v2.overlay import OverlayConfig

        cfg = OverlayConfig(mount_point="/mnt/x", route_rules=[])
        assert cfg.volumes_root == "/Volumes"


# ---------------------------------------------------------------------------
# _resolve — path routing logic
# ---------------------------------------------------------------------------


class TestResolve:
    def test_projects_prefix_resolved(self, overlay) -> None:
        assert overlay._resolve("/projects") == "/Volumes/DDRV904/projects"

    def test_projects_subpath(self, overlay) -> None:
        assert overlay._resolve("/projects/foo/bar") == "/Volumes/DDRV904/projects/foo/bar"

    def test_hooks_prefix_resolved(self, overlay) -> None:
        assert overlay._resolve("/hooks") == "/Volumes/DDRV900/hooks"

    def test_hooks_subpath(self, overlay) -> None:
        assert overlay._resolve("/hooks/pre-commit") == "/Volumes/DDRV900/hooks/pre-commit"

    def test_cache_prefix_empty_subpath(self, overlay) -> None:
        # target_subpath is "" so /cache maps to /Volumes/DDRV901
        assert overlay._resolve("/cache") == "/Volumes/DDRV901"

    def test_cache_subpath_no_double_slash(self, overlay) -> None:
        result = overlay._resolve("/cache/npm")
        assert "//" not in result
        assert result == "/Volumes/DDRV901/npm"

    def test_default_volume_fallback(self, overlay) -> None:
        # /docs has no matching rule → falls to default_volume DDRV904
        assert overlay._resolve("/docs") == "/Volumes/DDRV904/docs"

    def test_root_path_uses_default_volume(self, overlay) -> None:
        result = overlay._resolve("/")
        assert "DDRV904" in result

    def test_first_matching_prefix_wins(self) -> None:
        """A longer prefix that matches later must NOT override the first rule."""
        from devdrive_v2.overlay import OverlayConfig, OverlayFS

        cfg = OverlayConfig(
            mount_point="/mnt/x",
            route_rules=[
                {"prefix": "/projects",         "volume": "VOL_A", "target_subpath": "a"},
                {"prefix": "/projects/special",  "volume": "VOL_B", "target_subpath": "b"},
            ],
            volumes_root="/Volumes",
        )
        fs = OverlayFS(cfg)
        # /projects/special matches the FIRST rule (prefix=/projects), not the second.
        result = fs._resolve("/projects/special/x")
        assert "VOL_A" in result
        assert "VOL_B" not in result

    def test_prefix_not_matched_by_partial_component(self) -> None:
        """'/projectsX' must NOT match a rule with prefix '/projects'."""
        from devdrive_v2.overlay import OverlayConfig, OverlayFS

        cfg = OverlayConfig(
            mount_point="/mnt/x",
            route_rules=[
                {"prefix": "/projects", "volume": "VOL_PROJ", "target_subpath": ""},
            ],
            default_volume="VOL_DEFAULT",
            volumes_root="/Volumes",
        )
        fs = OverlayFS(cfg)
        result = fs._resolve("/projectsX/foo")
        assert "VOL_PROJ" not in result
        assert "VOL_DEFAULT" in result

    def test_exact_prefix_match(self, overlay) -> None:
        """Exact match on prefix (no trailing components) should work."""
        assert overlay._resolve("/hooks") == "/Volumes/DDRV900/hooks"

    def test_no_rules_no_default_produces_unmapped(self) -> None:
        from devdrive_v2.overlay import OverlayConfig, OverlayFS

        cfg = OverlayConfig(
            mount_point="/mnt/x",
            route_rules=[],
            default_volume="",
            volumes_root="/Volumes",
        )
        fs = OverlayFS(cfg)
        result = fs._resolve("/anything")
        assert "__unmapped__" in result

    def test_no_double_slashes_in_resolved_path(self, overlay) -> None:
        for vpath in ["/projects", "/projects/a", "/cache", "/cache/b", "/hooks/x/y"]:
            assert "//" not in overlay._resolve(vpath), vpath

    def test_normpath_applied(self, overlay) -> None:
        # Even with redundant separators in the virtual path the result is normalised.
        result = overlay._resolve("/projects/./foo/../bar")
        assert "/." not in result
        assert "bar" in result


# ---------------------------------------------------------------------------
# _extract_volume helper
# ---------------------------------------------------------------------------


class TestExtractVolume:
    def test_under_volumes_root(self) -> None:
        from devdrive_v2.overlay import _extract_volume

        assert _extract_volume("/Volumes/DDRV904/projects/foo", "/Volumes") == "DDRV904"

    def test_volume_root_itself(self) -> None:
        from devdrive_v2.overlay import _extract_volume

        assert _extract_volume("/Volumes/DDRV904", "/Volumes") == "DDRV904"

    def test_not_under_volumes_root(self) -> None:
        from devdrive_v2.overlay import _extract_volume

        assert _extract_volume("/tmp/foo", "/Volumes") == ""

    def test_custom_volumes_root(self) -> None:
        from devdrive_v2.overlay import _extract_volume

        result = _extract_volume("/private/var/volumes/MYVOL/data", "/private/var/volumes")
        assert result == "MYVOL"


# ---------------------------------------------------------------------------
# rename — cross-volume detection
# ---------------------------------------------------------------------------


class TestRename:
    def test_same_volume_rename_delegates_to_os(self, overlay, tmp_path) -> None:
        # Point both paths to a real temp dir so os.rename actually works.
        src = tmp_path / "src.txt"
        dst = tmp_path / "dst.txt"
        src.write_text("hello")

        with patch.object(overlay, "_resolve") as mock_resolve:
            mock_resolve.side_effect = [str(src), str(dst)]
            # Patch _extract_volume to return the same volume for both.
            with patch("devdrive_v2.overlay._extract_volume", return_value="DDRV904"):
                overlay.rename("/projects/src.txt", "/projects/dst.txt")
        assert dst.exists()

    def test_cross_volume_rename_raises_exdev(self, overlay) -> None:
        with patch.object(overlay, "_resolve", side_effect=[
            "/Volumes/DDRV904/projects/a",
            "/Volumes/DDRV900/hooks/a",
        ]):
            with patch("devdrive_v2.overlay._extract_volume", side_effect=["DDRV904", "DDRV900"]):
                with pytest.raises(OSError) as exc_info:
                    overlay.rename("/projects/a", "/hooks/a")
                assert exc_info.value.errno == errno.EXDEV


# ---------------------------------------------------------------------------
# statfs — graceful degradation when volume is not mounted
# ---------------------------------------------------------------------------


class TestStatfs:
    def test_statfs_returns_dict_with_expected_keys(self, overlay, tmp_path) -> None:
        with patch.object(overlay, "_resolve", return_value=str(tmp_path)):
            result = overlay.statfs("/projects")
        expected_keys = {
            "f_bsize", "f_frsize", "f_blocks", "f_bfree",
            "f_bavail", "f_files", "f_ffree", "f_favail", "f_flag", "f_namemax",
        }
        assert expected_keys.issubset(result.keys())

    def test_statfs_unmounted_volume_returns_zeroed_dict(self, overlay) -> None:
        """When statvfs raises OSError, return zeroed stats rather than propagating."""
        with patch.object(overlay, "_resolve", return_value="/nonexistent_root/__vol__/foo"):
            with patch("os.statvfs", side_effect=OSError("device not found")):
                result = overlay.statfs("/ghost")
        assert result["f_blocks"] == 0
        assert result["f_bsize"] == 4096


# ---------------------------------------------------------------------------
# FUSE operations — delegate to os.* on resolved real path
# ---------------------------------------------------------------------------


class TestFuseOps:
    """Exercise FUSE operations using real temp files — no macFUSE needed."""

    def test_getattr_existing_file(self, overlay, tmp_path) -> None:
        f = tmp_path / "hello.txt"
        f.write_bytes(b"abc")
        with patch.object(overlay, "_resolve", return_value=str(f)):
            attrs = overlay.getattr("/projects/hello.txt")
        assert attrs["st_size"] == 3
        assert stat.S_ISREG(attrs["st_mode"])

    def test_getattr_missing_file_raises_enoent(self, overlay, tmp_path) -> None:
        with patch.object(overlay, "_resolve", return_value=str(tmp_path / "ghost.txt")):
            with pytest.raises(OSError) as exc_info:
                overlay.getattr("/projects/ghost.txt")
            assert exc_info.value.errno == errno.ENOENT

    def test_readdir_returns_entries(self, overlay, tmp_path) -> None:
        (tmp_path / "a.py").write_text("")
        (tmp_path / "b.py").write_text("")
        with patch.object(overlay, "_resolve", return_value=str(tmp_path)):
            entries = overlay.readdir("/projects", 0)
        assert "." in entries
        assert ".." in entries
        assert "a.py" in entries
        assert "b.py" in entries

    def test_readdir_missing_dir_raises_enoent(self, overlay, tmp_path) -> None:
        with patch.object(overlay, "_resolve", return_value=str(tmp_path / "ghost_dir")):
            with pytest.raises(OSError) as exc_info:
                overlay.readdir("/projects/ghost_dir", 0)
            assert exc_info.value.errno == errno.ENOENT

    def test_create_open_read_write_release_cycle(self, overlay, tmp_path) -> None:
        target = tmp_path / "new.txt"
        with patch.object(overlay, "_resolve", return_value=str(target)):
            fd = overlay.create("/projects/new.txt", 0o644)
        try:
            payload = b"devdrive-v2"
            overlay.write("/projects/new.txt", payload, 0, fd)
        finally:
            overlay.release("/projects/new.txt", fd)

        assert target.read_bytes() == payload

    def test_read_returns_correct_bytes(self, overlay, tmp_path) -> None:
        target = tmp_path / "data.bin"
        target.write_bytes(b"ABCDEFGH")
        with patch.object(overlay, "_resolve", return_value=str(target)):
            fd = overlay.open("/projects/data.bin", os.O_RDONLY)
        try:
            data = overlay.read("/projects/data.bin", 4, 2, fd)
        finally:
            overlay.release("/projects/data.bin", fd)
        assert data == b"CDEF"

    def test_mkdir_and_rmdir(self, overlay, tmp_path) -> None:
        new_dir = tmp_path / "subdir"
        with patch.object(overlay, "_resolve", return_value=str(new_dir)):
            overlay.mkdir("/projects/subdir", 0o755)
        assert new_dir.is_dir()
        with patch.object(overlay, "_resolve", return_value=str(new_dir)):
            overlay.rmdir("/projects/subdir")
        assert not new_dir.exists()

    def test_unlink(self, overlay, tmp_path) -> None:
        f = tmp_path / "to_delete.txt"
        f.write_text("bye")
        with patch.object(overlay, "_resolve", return_value=str(f)):
            overlay.unlink("/projects/to_delete.txt")
        assert not f.exists()


# ---------------------------------------------------------------------------
# Import-guard — fusepy absent
# ---------------------------------------------------------------------------


class TestImportGuard:
    """Verify the module handles a missing fusepy gracefully."""

    def test_fuse_available_flag_type(self) -> None:
        import devdrive_v2.overlay as m

        assert isinstance(m._FUSE_AVAILABLE, bool)

    def test_overlay_fs_instantiates_without_fuse(self, basic_config) -> None:
        """OverlayFS must be constructable even when fusepy is absent."""
        from devdrive_v2.overlay import OverlayFS

        # Just instantiating must not raise.
        fs = OverlayFS(basic_config)
        assert fs.config is basic_config

    def test_mount_raises_runtime_error_when_fuse_unavailable(self, basic_config) -> None:
        import devdrive_v2.overlay as m
        from devdrive_v2.overlay import OverlayFS

        original = m._FUSE_AVAILABLE
        try:
            m._FUSE_AVAILABLE = False
            fs = OverlayFS(basic_config)
            with pytest.raises(RuntimeError, match="fusepy is not installed"):
                fs.mount()
        finally:
            m._FUSE_AVAILABLE = original

    def test_resolve_works_without_fuse(self, basic_config) -> None:
        """_resolve must work with no FUSE installed — it never touches FUSE."""
        import devdrive_v2.overlay as m
        from devdrive_v2.overlay import OverlayFS

        original = m._FUSE_AVAILABLE
        try:
            m._FUSE_AVAILABLE = False
            fs = OverlayFS(basic_config)
            assert fs._resolve("/projects/test") == "/Volumes/DDRV904/projects/test"
        finally:
            m._FUSE_AVAILABLE = original

    def test_module_importable_when_fuse_missing_from_sys_modules(self) -> None:
        """Re-import overlay with fuse blocked from sys.modules — must not crash."""
        # Save state.
        saved_fuse = sys.modules.pop("fuse", None)
        saved_overlay = sys.modules.pop("devdrive_v2.overlay", None)

        # Block fuse import.
        sys.modules["fuse"] = None  # type: ignore[assignment]
        try:
            mod = importlib.import_module("devdrive_v2.overlay")
            assert mod._FUSE_AVAILABLE is False
        finally:
            # Restore.
            if saved_fuse is None:
                sys.modules.pop("fuse", None)
            else:
                sys.modules["fuse"] = saved_fuse
            if saved_overlay is not None:
                sys.modules["devdrive_v2.overlay"] = saved_overlay
            else:
                sys.modules.pop("devdrive_v2.overlay", None)


# ---------------------------------------------------------------------------
# measure_performance — no FUSE required
# ---------------------------------------------------------------------------


class TestMeasurePerformance:
    """Exercise measure_performance with two real tmp directories."""

    def test_returns_expected_keys(self, tmp_path) -> None:
        from devdrive_v2.overlay import measure_performance

        overlay_dir = str(tmp_path / "overlay")
        direct_dir = str(tmp_path / "direct")
        result = measure_performance(overlay_dir, direct_dir, ops=5)

        assert result["ops"] == 5
        assert "overlay" in result
        assert "direct" in result
        assert "overhead_us" in result
        assert "note" in result

    def test_overlay_sub_dict_keys(self, tmp_path) -> None:
        from devdrive_v2.overlay import measure_performance

        result = measure_performance(
            str(tmp_path / "a"), str(tmp_path / "b"), ops=3
        )
        for key in ("path", "total_s", "mean_us"):
            assert key in result["overlay"], f"missing key {key!r} in overlay sub-dict"
            assert key in result["direct"], f"missing key {key!r} in direct sub-dict"

    def test_paths_recorded_in_result(self, tmp_path) -> None:
        from devdrive_v2.overlay import measure_performance

        ov = str(tmp_path / "ov")
        dr = str(tmp_path / "dr")
        result = measure_performance(ov, dr, ops=2)
        assert result["overlay"]["path"] == ov
        assert result["direct"]["path"] == dr

    def test_total_seconds_positive(self, tmp_path) -> None:
        from devdrive_v2.overlay import measure_performance

        result = measure_performance(str(tmp_path / "x"), str(tmp_path / "y"), ops=10)
        assert result["overlay"]["total_s"] > 0
        assert result["direct"]["total_s"] > 0

    def test_mean_us_positive(self, tmp_path) -> None:
        from devdrive_v2.overlay import measure_performance

        result = measure_performance(str(tmp_path / "x"), str(tmp_path / "y"), ops=10)
        assert result["overlay"]["mean_us"] > 0
        assert result["direct"]["mean_us"] > 0

    def test_note_is_string(self, tmp_path) -> None:
        from devdrive_v2.overlay import measure_performance

        result = measure_performance(str(tmp_path / "x"), str(tmp_path / "y"), ops=2)
        assert isinstance(result["note"], str)
        assert len(result["note"]) > 0

    def test_overhead_is_float_or_none(self, tmp_path) -> None:
        from devdrive_v2.overlay import measure_performance

        result = measure_performance(str(tmp_path / "x"), str(tmp_path / "y"), ops=5)
        assert result["overhead_us"] is None or isinstance(result["overhead_us"], float)

    def test_creates_dirs_if_missing(self, tmp_path) -> None:
        from devdrive_v2.overlay import measure_performance

        # Paths do not exist yet — measure_performance must create them.
        ov = str(tmp_path / "deep" / "overlay")
        dr = str(tmp_path / "deep" / "direct")
        # Should not raise.
        measure_performance(ov, dr, ops=2)
        assert Path(ov).is_dir()
        assert Path(dr).is_dir()

    def test_no_temp_files_left_behind(self, tmp_path) -> None:
        from devdrive_v2.overlay import measure_performance

        ov = str(tmp_path / "ov")
        dr = str(tmp_path / "dr")
        measure_performance(ov, dr, ops=10)
        ov_files = list(Path(ov).glob("_lfg_bench_*.tmp"))
        dr_files = list(Path(dr).glob("_lfg_bench_*.tmp"))
        assert ov_files == [], f"leftover overlay files: {ov_files}"
        assert dr_files == [], f"leftover direct files: {dr_files}"


# ---------------------------------------------------------------------------
# import stat needed by TestFuseOps
# ---------------------------------------------------------------------------
import stat  # noqa: E402  (placed after class definitions to satisfy linters)

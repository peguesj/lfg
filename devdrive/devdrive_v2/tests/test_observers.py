"""Tests for devdrive_v2.observers — all subprocess calls are mocked.

Run with:
    PYTHONPATH=lib pytest lib/devdrive_v2/tests/test_observers.py -v
"""

from __future__ import annotations

import plistlib
import subprocess
import tempfile
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

from devdrive_v2.observers import (
    BandBloatWatch,
    ClangCacheWatch,
    DockerWatch,
    PurgeableWatch,
    _parse_human_size_to_gb,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _completed(stdout: str = "", returncode: int = 0) -> subprocess.CompletedProcess[str]:
    """Build a fake CompletedProcess for use in mock return values."""
    cp: subprocess.CompletedProcess[str] = subprocess.CompletedProcess(
        args=[], returncode=returncode, stdout=stdout, stderr=""
    )
    return cp


def _plist_bytes(data: dict[str, Any]) -> str:
    """Encode *data* as a plist XML string (simulates diskutil -plist output)."""
    return plistlib.dumps(data, fmt=plistlib.FMT_XML).decode()


# ---------------------------------------------------------------------------
# _parse_human_size_to_gb
# ---------------------------------------------------------------------------


class TestParseHumanSizeToGb:
    def test_gigabytes(self) -> None:
        assert _parse_human_size_to_gb("45G") == pytest.approx(45.0)

    def test_terabytes(self) -> None:
        assert _parse_human_size_to_gb("1T") == pytest.approx(1000.0)

    def test_megabytes(self) -> None:
        assert _parse_human_size_to_gb("500M") == pytest.approx(0.5)

    def test_kilobytes(self) -> None:
        assert _parse_human_size_to_gb("1000K") == pytest.approx(1e-3)

    def test_decimal(self) -> None:
        assert _parse_human_size_to_gb("1.2G") == pytest.approx(1.2)

    def test_lowercase_suffix(self) -> None:
        assert _parse_human_size_to_gb("20g") == pytest.approx(20.0)

    def test_empty_string(self) -> None:
        assert _parse_human_size_to_gb("") == 0.0

    def test_no_suffix_bytes(self) -> None:
        assert _parse_human_size_to_gb("1000000000") == pytest.approx(1.0)

    def test_garbage(self) -> None:
        assert _parse_human_size_to_gb("???") == 0.0


# ---------------------------------------------------------------------------
# PurgeableWatch
# ---------------------------------------------------------------------------

_DF_HAPPY = (
    "Filesystem      Size   Used  Avail Capacity iused ifree %iused  Mounted on\n"
    "/dev/disk3s1s1  500G   320G   45G    88%    ...   ...   ...     /\n"
)

_DISKUTIL_PLIST_HAPPY: dict[str, Any] = {
    "APFSContainerFree": 120_000_000_000,
    "APFSContainerPurgeable": 30_000_000_000,
}


class TestPurgeableWatch:
    def test_happy_path(self) -> None:
        plist_str = _plist_bytes(_DISKUTIL_PLIST_HAPPY)
        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = [
                _completed(_DF_HAPPY),           # df -H /
                _completed(plist_str),            # diskutil info -plist /
            ]
            result = PurgeableWatch().observe()

        assert result["df_free_gb"] == pytest.approx(45.0)
        assert result["container_free_gb"] == pytest.approx(120.0)
        assert result["purgeable_gb"] == pytest.approx(30.0)
        assert mock_run.call_count == 2
        assert mock_run.call_args_list[0][0][0] == ["df", "-H", "/"]
        assert mock_run.call_args_list[1][0][0] == ["diskutil", "info", "-plist", "/"]

    def test_df_nonzero_returncode(self) -> None:
        plist_str = _plist_bytes(_DISKUTIL_PLIST_HAPPY)
        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = [
                _completed("", returncode=1),
                _completed(plist_str),
            ]
            result = PurgeableWatch().observe()

        assert result["df_free_gb"] == 0.0
        assert result["container_free_gb"] == pytest.approx(120.0)

    def test_df_empty_output(self) -> None:
        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = [
                _completed(""),
                _completed(""),
            ]
            result = PurgeableWatch().observe()

        assert result["df_free_gb"] == 0.0
        assert result["purgeable_gb"] == 0.0

    def test_diskutil_missing_tool(self) -> None:
        """diskutil raises FileNotFoundError (tool absent)."""
        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = [
                _completed(_DF_HAPPY),
                FileNotFoundError("diskutil not found"),
            ]
            result = PurgeableWatch().observe()

        assert result["df_free_gb"] == pytest.approx(45.0)
        assert result["container_free_gb"] == 0.0
        assert result["purgeable_gb"] == 0.0

    def test_diskutil_bad_plist(self) -> None:
        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = [
                _completed(_DF_HAPPY),
                _completed("not-a-plist"),
            ]
            result = PurgeableWatch().observe()

        assert result["purgeable_gb"] == 0.0

    def test_diskutil_fallback_to_free_space_key(self) -> None:
        """When APFSContainerFree absent, FreeSpace is used as container_free."""
        plist_str = _plist_bytes({"FreeSpace": 80_000_000_000, "APFSContainerPurgeable": 5_000_000_000})
        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = [
                _completed(_DF_HAPPY),
                _completed(plist_str),
            ]
            result = PurgeableWatch().observe()

        assert result["container_free_gb"] == pytest.approx(80.0)
        assert result["purgeable_gb"] == pytest.approx(5.0)

    def test_df_only_header_line(self) -> None:
        """df output with only a header should yield 0.0."""
        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = [
                _completed("Filesystem  Size  Used  Avail Capacity  Mounted on\n"),
                _completed(""),
            ]
            result = PurgeableWatch().observe()

        assert result["df_free_gb"] == 0.0

    def test_subprocess_timeout(self) -> None:
        """Timeout from subprocess propagates cleanly → zeroed metrics."""
        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = subprocess.TimeoutExpired(cmd="df", timeout=10)
            result = PurgeableWatch().observe()

        assert result["df_free_gb"] == 0.0


# ---------------------------------------------------------------------------
# ClangCacheWatch
# ---------------------------------------------------------------------------


class TestClangCacheWatch:
    def test_happy_path(self, tmp_path: Path) -> None:
        derived = tmp_path / "DerivedData"
        derived.mkdir()

        with patch("devdrive_v2.observers.ClangCacheWatch._DERIVED_DATA", derived):
            with patch("devdrive_v2.observers._run") as mock_du:
                # du -sk DerivedData
                mock_du.return_value = _completed(f"2097152\t{derived}\n")
                with patch("subprocess.run") as mock_sh:
                    # /bin/sh -c du -sk /tmp/clang-*
                    mock_sh.return_value = _completed("512000\t/tmp/clang-abc\n1024000\t/tmp/clang-def\n")
                    result = ClangCacheWatch().observe()

        assert result["derived_data_mb"] == pytest.approx(2097152 / 1024)
        assert result["clang_tmp_mb"] == pytest.approx((512000 + 1024000) / 1024)

    def test_derived_data_missing(self, tmp_path: Path) -> None:
        """Path that does not exist should yield 0.0 without calling du."""
        missing = tmp_path / "NonExistent"

        with patch("devdrive_v2.observers.ClangCacheWatch._DERIVED_DATA", missing):
            with patch("devdrive_v2.observers._run") as mock_du:
                with patch("subprocess.run") as mock_sh:
                    mock_sh.return_value = _completed("")
                    result = ClangCacheWatch().observe()

        mock_du.assert_not_called()
        assert result["derived_data_mb"] == 0.0

    def test_clang_glob_no_matches(self, tmp_path: Path) -> None:
        derived = tmp_path / "DerivedData"
        derived.mkdir()

        with patch("devdrive_v2.observers.ClangCacheWatch._DERIVED_DATA", derived):
            with patch("devdrive_v2.observers._run") as mock_du:
                mock_du.return_value = _completed(f"0\t{derived}\n")
                with patch("subprocess.run") as mock_sh:
                    mock_sh.return_value = _completed("")
                    result = ClangCacheWatch().observe()

        assert result["clang_tmp_mb"] == 0.0

    def test_du_nonzero_returncode(self, tmp_path: Path) -> None:
        derived = tmp_path / "DerivedData"
        derived.mkdir()

        with patch("devdrive_v2.observers.ClangCacheWatch._DERIVED_DATA", derived):
            with patch("devdrive_v2.observers._run") as mock_du:
                mock_du.return_value = _completed("", returncode=1)
                with patch("subprocess.run") as mock_sh:
                    mock_sh.return_value = _completed("")
                    result = ClangCacheWatch().observe()

        assert result["derived_data_mb"] == 0.0

    def test_du_raises_exception(self, tmp_path: Path) -> None:
        derived = tmp_path / "DerivedData"
        derived.mkdir()

        with patch("devdrive_v2.observers.ClangCacheWatch._DERIVED_DATA", derived):
            with patch("devdrive_v2.observers._run") as mock_du:
                mock_du.side_effect = OSError("permission denied")
                with patch("subprocess.run") as mock_sh:
                    mock_sh.return_value = _completed("")
                    result = ClangCacheWatch().observe()

        assert result["derived_data_mb"] == 0.0

    def test_clang_glob_malformed_line(self, tmp_path: Path) -> None:
        """Lines with no numeric first column are skipped gracefully."""
        derived = tmp_path / "DerivedData"
        derived.mkdir()

        with patch("devdrive_v2.observers.ClangCacheWatch._DERIVED_DATA", derived):
            with patch("devdrive_v2.observers._run") as mock_du:
                mock_du.return_value = _completed(f"100\t{derived}\n")
                with patch("subprocess.run") as mock_sh:
                    mock_sh.return_value = _completed("du: bad line\n1024\t/tmp/clang-x\n")
                    result = ClangCacheWatch().observe()

        # "du: bad line" has no numeric first token; only 1024 KB counted
        assert result["clang_tmp_mb"] == pytest.approx(1024 / 1024)


# ---------------------------------------------------------------------------
# BandBloatWatch
# ---------------------------------------------------------------------------


class TestBandBloatWatch:
    def _make_image(self, base: Path, name: str) -> Path:
        """Create a fake sparseimage bundle directory."""
        img = base / name
        img.mkdir()
        (img / "bands").mkdir()
        return img

    def test_happy_path(self, tmp_path: Path) -> None:
        img1 = self._make_image(tmp_path, "data.sparseimage")
        img2 = self._make_image(tmp_path, "cache.sparseimage")

        ls_data = "0\n1\n2\n3\n4\n"        # 5 bands
        ls_cache = "0\n1\n"               # 2 bands
        du_data = f"204800\t{img1}\n"     # 200 MB
        du_cache = f"102400\t{img2}\n"    # 100 MB

        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = [
                _completed(ls_data),   # ls bands/ for cache.sparseimage (alphabetical)
                _completed(du_cache),
                _completed(ls_data),   # ls bands/ for data.sparseimage
                _completed(du_data),
            ]
            result = BandBloatWatch(images_dir=tmp_path).observe()

        images = result["images"]
        assert len(images) == 2
        names = {img["name"] for img in images}
        assert "cache.sparseimage" in names
        assert "data.sparseimage" in names
        for img in images:
            assert isinstance(img["band_count"], int)
            assert isinstance(img["size_mb"], float)

    def test_no_images_dir(self, tmp_path: Path) -> None:
        missing = tmp_path / "no_such_dir"
        result = BandBloatWatch(images_dir=missing).observe()
        assert result == {"images": []}

    def test_empty_images_dir(self, tmp_path: Path) -> None:
        """Directory exists but contains no .sparseimage files."""
        result = BandBloatWatch(images_dir=tmp_path).observe()
        assert result == {"images": []}

    def test_ls_nonzero_returncode(self, tmp_path: Path) -> None:
        img = self._make_image(tmp_path, "broken.sparseimage")

        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = [
                _completed("", returncode=1),    # ls fails
                _completed(f"1024\t{img}\n"),    # du succeeds
            ]
            result = BandBloatWatch(images_dir=tmp_path).observe()

        assert result["images"][0]["band_count"] == 0
        assert result["images"][0]["size_mb"] == pytest.approx(1.0)

    def test_ls_empty_bands(self, tmp_path: Path) -> None:
        self._make_image(tmp_path, "empty.sparseimage")

        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = [
                _completed(""),    # ls returns nothing
                _completed("0\t/path\n"),
            ]
            result = BandBloatWatch(images_dir=tmp_path).observe()

        assert result["images"][0]["band_count"] == 0

    def test_du_raises_exception(self, tmp_path: Path) -> None:
        img = self._make_image(tmp_path, "img.sparseimage")

        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = [
                _completed("0\n1\n"),               # ls OK
                OSError("I/O error"),               # du raises
            ]
            result = BandBloatWatch(images_dir=tmp_path).observe()

        assert result["images"][0]["size_mb"] == 0.0
        assert result["images"][0]["band_count"] == 2

    def test_default_images_dir_path(self) -> None:
        """Verify the default dir matches the spec."""
        from devdrive_v2.observers import _DEFAULT_IMAGES_DIR
        watch = BandBloatWatch()
        assert watch.images_dir == _DEFAULT_IMAGES_DIR

    def test_band_count_ignores_blank_lines(self, tmp_path: Path) -> None:
        """ls output with trailing newline should not inflate band count."""
        self._make_image(tmp_path, "a.sparseimage")

        with patch("devdrive_v2.observers._run") as mock_run:
            mock_run.side_effect = [
                _completed("0\n1\n\n"),   # trailing blank line
                _completed("512\t/x\n"),
            ]
            result = BandBloatWatch(images_dir=tmp_path).observe()

        assert result["images"][0]["band_count"] == 2


# ---------------------------------------------------------------------------
# DockerWatch
# ---------------------------------------------------------------------------


class TestDockerWatch:
    def test_happy_path_running(self, tmp_path: Path) -> None:
        raw = tmp_path / "Docker.raw"
        raw.write_bytes(b"")

        with patch.object(DockerWatch, "_DOCKER_RAW", raw):
            with patch("devdrive_v2.observers._run") as mock_run:
                mock_run.side_effect = [
                    _completed(f"60000000\t{raw}\n"),   # du -sk Docker.raw (≈ 60 GB)
                    _completed("Server: Docker Desktop\n"),  # docker info
                ]
                result = DockerWatch().observe()

        assert result["docker_raw_gb"] == pytest.approx(60.0)
        assert result["docker_running"] is True

    def test_docker_raw_not_present(self, tmp_path: Path) -> None:
        missing = tmp_path / "Docker.raw"  # does not exist

        with patch.object(DockerWatch, "_DOCKER_RAW", missing):
            with patch("devdrive_v2.observers._run") as mock_run:
                mock_run.return_value = _completed("")  # docker info (not running)
                result = DockerWatch().observe()

        assert result["docker_raw_gb"] == 0.0

    def test_docker_not_running(self, tmp_path: Path) -> None:
        raw = tmp_path / "Docker.raw"
        raw.write_bytes(b"")

        with patch.object(DockerWatch, "_DOCKER_RAW", raw):
            with patch("devdrive_v2.observers._run") as mock_run:
                mock_run.side_effect = [
                    _completed(f"30000000\t{raw}\n"),
                    _completed("", returncode=1),      # docker info fails → not running
                ]
                result = DockerWatch().observe()

        assert result["docker_raw_gb"] == pytest.approx(30.0)
        assert result["docker_running"] is False

    def test_docker_info_raises(self, tmp_path: Path) -> None:
        raw = tmp_path / "Docker.raw"
        raw.write_bytes(b"")

        with patch.object(DockerWatch, "_DOCKER_RAW", raw):
            with patch("devdrive_v2.observers._run") as mock_run:
                mock_run.side_effect = [
                    _completed(f"10000000\t{raw}\n"),
                    FileNotFoundError("docker not found"),
                ]
                result = DockerWatch().observe()

        assert result["docker_running"] is False

    def test_du_nonzero_returncode(self, tmp_path: Path) -> None:
        raw = tmp_path / "Docker.raw"
        raw.write_bytes(b"")

        with patch.object(DockerWatch, "_DOCKER_RAW", raw):
            with patch("devdrive_v2.observers._run") as mock_run:
                mock_run.side_effect = [
                    _completed("", returncode=1),
                    _completed(""),
                ]
                result = DockerWatch().observe()

        assert result["docker_raw_gb"] == 0.0

    def test_du_raises_exception(self, tmp_path: Path) -> None:
        raw = tmp_path / "Docker.raw"
        raw.write_bytes(b"")

        with patch.object(DockerWatch, "_DOCKER_RAW", raw):
            with patch("devdrive_v2.observers._run") as mock_run:
                mock_run.side_effect = [
                    subprocess.TimeoutExpired(cmd="du", timeout=10),
                    _completed(""),
                ]
                result = DockerWatch().observe()

        assert result["docker_raw_gb"] == 0.0

    def test_docker_raw_size_conversion(self, tmp_path: Path) -> None:
        """1 000 000 KB should equal 1 GB."""
        raw = tmp_path / "Docker.raw"
        raw.write_bytes(b"")

        with patch.object(DockerWatch, "_DOCKER_RAW", raw):
            with patch("devdrive_v2.observers._run") as mock_run:
                mock_run.side_effect = [
                    _completed(f"1000000\t{raw}\n"),
                    _completed("ok"),
                ]
                result = DockerWatch().observe()

        assert result["docker_raw_gb"] == pytest.approx(1.0)

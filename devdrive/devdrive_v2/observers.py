"""DevDrive v2 pressure observers — one observer per pressure source.

Each observer exposes a single ``observe() -> dict`` method.  All
subprocess calls are isolated behind ``subprocess.run`` so tests can
patch them without spawning real processes.

Observers never raise; on any error or missing tool they return a dict
of zeroed metrics so the caller can always merge results safely.
"""

from __future__ import annotations

import plistlib
import subprocess
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_DEFAULT_IMAGES_DIR = Path.home() / ".config" / "lfg" / "images"


def _run(args: list[str], timeout: int = 10) -> subprocess.CompletedProcess[str]:
    """Thin wrapper around subprocess.run to make patching straightforward.

    Args:
        args: Command and arguments passed to subprocess.run.
        timeout: Wall-clock timeout in seconds.

    Returns:
        A CompletedProcess instance (stdout/stderr as str).
    """
    return subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


# ---------------------------------------------------------------------------
# PurgeableWatch
# ---------------------------------------------------------------------------


class PurgeableWatch:
    """Reports root-filesystem free space and APFS purgeable bytes.

    Uses ``df -H /`` for raw free space and ``diskutil info -plist /``
    for the container-level free and purgeable figures reported by APFS.

    Returns:
        dict with keys:
            df_free_gb (float): Free gigabytes as reported by ``df``.
            container_free_gb (float): APFS container free space in GB.
            purgeable_gb (float): APFS purgeable space in GB.
    """

    def observe(self) -> dict[str, Any]:
        """Collect purgeable-space metrics.

        Returns:
            Metric dict; all values are 0.0 on parse/subprocess failure.
        """
        df_free_gb = self._read_df_free()
        container_free_gb, purgeable_gb = self._read_diskutil_purgeable()
        return {
            "df_free_gb": df_free_gb,
            "container_free_gb": container_free_gb,
            "purgeable_gb": purgeable_gb,
        }

    def _read_df_free(self) -> float:
        """Parse ``df -H /`` and return free space in GB.

        ``df -H`` uses SI prefixes (1 GB = 1 000 000 000 bytes).  The
        free column contains a numeric value followed by a unit suffix
        such as ``45G`` or ``1.2T``.

        Returns:
            Free space in GB, or 0.0 on any error.
        """
        try:
            result = _run(["df", "-H", "/"])
            if result.returncode != 0 or not result.stdout:
                return 0.0
            lines = result.stdout.strip().splitlines()
            # Header line + at least one data line
            if len(lines) < 2:
                return 0.0
            # Filesystem  Size  Used  Avail Capacity  iused  ifree %iused  Mounted on
            # /dev/disk3  500G  320G   45G    88%     ...    /
            parts = lines[1].split()
            if len(parts) < 4:
                return 0.0
            raw = parts[3]  # "Avail" column
            return _parse_human_size_to_gb(raw)
        except Exception:
            return 0.0

    def _read_diskutil_purgeable(self) -> tuple[float, float]:
        """Parse ``diskutil info -plist /`` for APFS free/purgeable.

        Returns:
            Tuple of (container_free_gb, purgeable_gb).  Both are 0.0
            on any error.
        """
        try:
            result = _run(["diskutil", "info", "-plist", "/"])
            if result.returncode != 0 or not result.stdout:
                return 0.0, 0.0
            info: dict[str, Any] = plistlib.loads(result.stdout.encode())
            # Keys present in modern macOS diskutil plist output:
            # "FreeSpace" — total free (purgeable included)
            # "APFSContainerFree" — container-level free
            # "APFSContainerPurgeable" — purgeable portion
            container_free_bytes = float(
                info.get("APFSContainerFree", info.get("FreeSpace", 0))
            )
            purgeable_bytes = float(info.get("APFSContainerPurgeable", 0))
            return (
                container_free_bytes / 1e9,
                purgeable_bytes / 1e9,
            )
        except Exception:
            return 0.0, 0.0


# ---------------------------------------------------------------------------
# ClangCacheWatch
# ---------------------------------------------------------------------------


class ClangCacheWatch:
    """Reports disk usage of Xcode DerivedData and clang temp dirs.

    Uses ``du -sk`` which always outputs kilobytes regardless of locale.

    Returns:
        dict with keys:
            derived_data_mb (float): ~/Library/Developer/Xcode/DerivedData usage in MB.
            clang_tmp_mb (float): Combined /tmp/clang-* directory usage in MB.
    """

    _DERIVED_DATA = Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData"
    _CLANG_TMP_GLOB = "/tmp/clang-*"

    def observe(self) -> dict[str, Any]:
        """Collect clang/Xcode cache disk-usage metrics.

        Returns:
            Metric dict; values are 0.0 when the path does not exist or
            the subprocess fails.
        """
        return {
            "derived_data_mb": self._du_mb(str(self._DERIVED_DATA)),
            "clang_tmp_mb": self._du_glob_mb(self._CLANG_TMP_GLOB),
        }

    def _du_mb(self, path: str) -> float:
        """Return disk usage of *path* in megabytes via ``du -sk``.

        Args:
            path: Absolute path to measure.

        Returns:
            Usage in MB, or 0.0 on error / missing path.
        """
        try:
            if not Path(path).exists():
                return 0.0
            result = _run(["du", "-sk", path])
            if result.returncode != 0 or not result.stdout:
                return 0.0
            kb = float(result.stdout.split()[0])
            return kb / 1024.0
        except Exception:
            return 0.0

    def _du_glob_mb(self, pattern: str) -> float:
        """Return combined disk usage matching a shell glob via ``du -sk``.

        ``du`` accepts glob patterns directly when the shell expands them;
        here we pass the pattern as a single argument so that the OS/shell
        expands it.  We use ``shell=False`` to stay mockable, so we
        delegate the expansion by passing the glob as a ``du`` argument
        via a shell invocation through a POSIX sh wrapper.

        Args:
            pattern: Shell glob pattern, e.g. ``/tmp/clang-*``.

        Returns:
            Combined usage in MB, or 0.0 on error.
        """
        try:
            # Use /bin/sh to expand the glob so no real shell state leaks in.
            result = subprocess.run(
                ["/bin/sh", "-c", f"du -sk {pattern} 2>/dev/null"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if not result.stdout.strip():
                return 0.0
            total_kb = 0.0
            for line in result.stdout.strip().splitlines():
                parts = line.split()
                if parts:
                    try:
                        total_kb += float(parts[0])
                    except ValueError:
                        continue
            return total_kb / 1024.0
        except Exception:
            return 0.0


# ---------------------------------------------------------------------------
# BandBloatWatch
# ---------------------------------------------------------------------------


class BandBloatWatch:
    """Reports sparseimage band-file counts and sizes.

    Iterates over ``*.sparseimage`` files in *images_dir* and for each
    one reads the band count from its ``bands/`` directory using ``ls``.
    File size is obtained via ``du -sk``.

    Args:
        images_dir: Directory containing ``.sparseimage`` files.
                    Defaults to ``~/.config/lfg/images/``.

    Returns:
        dict with key:
            images (list[dict]): One entry per image with keys
                ``name`` (str), ``band_count`` (int), ``size_mb`` (float).
    """

    def __init__(self, images_dir: Path | None = None) -> None:
        self.images_dir: Path = images_dir or _DEFAULT_IMAGES_DIR

    def observe(self) -> dict[str, Any]:
        """Collect sparseimage band-bloat metrics.

        Returns:
            Metric dict with an ``images`` list.  Returns an empty list
            when the directory does not exist or contains no images.
        """
        results: list[dict[str, Any]] = []
        if not self.images_dir.exists():
            return {"images": results}

        for image_path in sorted(self.images_dir.glob("*.sparseimage")):
            band_count = self._count_bands(image_path)
            size_mb = self._image_size_mb(image_path)
            results.append(
                {
                    "name": image_path.name,
                    "band_count": band_count,
                    "size_mb": size_mb,
                }
            )
        return {"images": results}

    def _count_bands(self, image_path: Path) -> int:
        """Count band files inside a sparseimage bundle.

        Sparseimage bundles store data in a ``bands/`` subdirectory as
        numbered files.  We list that directory with ``ls`` and count
        non-empty lines.

        Args:
            image_path: Path to the ``.sparseimage`` bundle.

        Returns:
            Number of band files, or 0 on error.
        """
        try:
            bands_dir = image_path / "bands"
            result = _run(["ls", str(bands_dir)])
            if result.returncode != 0 or not result.stdout.strip():
                return 0
            return len([l for l in result.stdout.strip().splitlines() if l.strip()])
        except Exception:
            return 0

    def _image_size_mb(self, image_path: Path) -> float:
        """Return disk usage of *image_path* in megabytes.

        Args:
            image_path: Path to the ``.sparseimage`` bundle.

        Returns:
            Size in MB, or 0.0 on error.
        """
        try:
            result = _run(["du", "-sk", str(image_path)])
            if result.returncode != 0 or not result.stdout:
                return 0.0
            kb = float(result.stdout.split()[0])
            return kb / 1024.0
        except Exception:
            return 0.0


# ---------------------------------------------------------------------------
# DockerWatch
# ---------------------------------------------------------------------------


class DockerWatch:
    """Reports Docker VM raw-disk image size and running status.

    Checks the size of ``Docker.raw`` (the VM backing store used by
    Docker Desktop on Apple Silicon / Intel Macs) and whether the
    Docker daemon is currently running.

    Returns:
        dict with keys:
            docker_raw_gb (float): Size of Docker.raw in GB.
            docker_running (bool): True if the Docker daemon responds.
    """

    _DOCKER_RAW = (
        Path.home()
        / "Library"
        / "Containers"
        / "com.docker.docker"
        / "Data"
        / "vms"
        / "0"
        / "data"
        / "Docker.raw"
    )

    def observe(self) -> dict[str, Any]:
        """Collect Docker disk-usage and daemon-status metrics.

        Returns:
            Metric dict; ``docker_raw_gb`` is 0.0 and ``docker_running``
            is False when Docker is not installed or not running.
        """
        return {
            "docker_raw_gb": self._docker_raw_gb(),
            "docker_running": self._docker_running(),
        }

    def _docker_raw_gb(self) -> float:
        """Return size of Docker.raw in gigabytes.

        Uses ``du -sk`` for consistency with the other observers.

        Returns:
            Size in GB, or 0.0 when the file does not exist.
        """
        try:
            if not self._DOCKER_RAW.exists():
                return 0.0
            result = _run(["du", "-sk", str(self._DOCKER_RAW)])
            if result.returncode != 0 or not result.stdout:
                return 0.0
            kb = float(result.stdout.split()[0])
            return kb / 1_000_000.0  # KB → GB (1 GB = 1 000 000 KB)
        except Exception:
            return 0.0

    def _docker_running(self) -> bool:
        """Check whether the Docker daemon responds to ``docker info``.

        Returns:
            True if ``docker info`` exits with code 0, False otherwise.
        """
        try:
            result = _run(["docker", "info"])
            return result.returncode == 0
        except Exception:
            return False


# ---------------------------------------------------------------------------
# Internal utilities
# ---------------------------------------------------------------------------


def _parse_human_size_to_gb(value: str) -> float:
    """Convert a human-readable size string (SI, as output by ``df -H``) to GB.

    ``df -H`` uses powers of 1000.  Recognised suffixes: K, M, G, T, P.

    Args:
        value: Size string such as ``"45G"``, ``"1.2T"``, or ``"512M"``.

    Returns:
        Equivalent gigabytes as a float, or 0.0 for unrecognised input.
    """
    suffixes: dict[str, float] = {
        "K": 1e-6,
        "M": 1e-3,
        "G": 1.0,
        "T": 1e3,
        "P": 1e6,
    }
    value = value.strip()
    if not value:
        return 0.0
    suffix = value[-1].upper()
    if suffix in suffixes:
        try:
            return float(value[:-1]) * suffixes[suffix]
        except ValueError:
            return 0.0
    # No suffix — assume bytes
    try:
        return float(value) / 1e9
    except ValueError:
        return 0.0

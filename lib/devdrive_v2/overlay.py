"""DevDrive v2 FSKit overlay — FUSE-based unified namespace over APFS volumes.

This module implements a proof-of-concept FUSE overlay filesystem that presents a
single virtual directory tree whose paths are transparently routed to distinct APFS
sparse-image volumes.  It targets macFUSE 5.2.0 (released 2026-04-09), which ships
an FSKit backend that removes the kernel-extension requirement on Apple Silicon Macs.

The Python binding is fusepy (``pip install fusepy``).  The module guards the import
so that the rest of the codebase — and the test suite — can load and exercise the
routing logic without macFUSE or fusepy being present on the machine.

Usage (requires macFUSE 5.2+ installed)::

    from devdrive_v2.overlay import OverlayConfig, OverlayFS

    config = OverlayConfig(
        mount_point="/mnt/devdrive",
        route_rules=[
            {"prefix": "/projects", "volume": "DDRV904", "target_subpath": "projects"},
            {"prefix": "/hooks",    "volume": "DDRV900", "target_subpath": "hooks"},
            {"prefix": "/cache",    "volume": "DDRV901", "target_subpath": ""},
        ],
        default_volume="DDRV904",
        volumes_root="/Volumes",
    )
    fs = OverlayFS(config)
    fs.mount()   # blocks; Ctrl-C or fs.unmount() from another thread to stop

Design notes
------------
* Route resolution is prefix-longest-match first — rules are evaluated in declaration
  order and the first match wins, consistent with typical overlay semantics.
* FUSE operations delegate to ``os.*`` / ``os.path.*`` calls on the resolved real path.
  No caching layer is introduced at this stage; the OS page cache does the heavy
  lifting for reads.
* ``statfs`` reports the aggregate of the default volume's statvfs so that tools like
  ``df`` show sensible numbers.
"""

from __future__ import annotations

import errno
import logging
import os
import stat
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Optional fusepy import — the entire fuse namespace is mocked when unavailable
# so that classes that inherit from fuse.Operations can still be defined and
# tested without macFUSE present.
# ---------------------------------------------------------------------------

try:
    import fuse  # type: ignore[import-untyped]

    _FUSE_AVAILABLE = True

    class _FuseOperationsBase(fuse.Operations):  # type: ignore[misc]
        pass

except ImportError:  # pragma: no cover -- covered by test_overlay.py mock path
    _FUSE_AVAILABLE = False

    class _FuseOperationsBase:  # type: ignore[no-redef]
        """Minimal stand-in for fuse.Operations when fusepy is not installed."""


# ---------------------------------------------------------------------------
# OverlayConfig
# ---------------------------------------------------------------------------


@dataclass
class OverlayConfig:
    """Configuration for the FUSE overlay filesystem.

    Attributes:
        mount_point: Absolute path where the overlay will be mounted.
        route_rules: Ordered list of routing rules.  Each rule is a dict with:

            * ``prefix``        — virtual path prefix (e.g. ``"/projects"``).
            * ``volume``        — APFS volume label / mount name (e.g. ``"DDRV904"``).
            * ``target_subpath``— sub-directory within the volume root
              (empty string means the volume root itself).

        default_volume: Volume to use when no rule prefix matches.
        volumes_root: Parent directory under which volumes are mounted
            (default ``"/Volumes"``).
    """

    mount_point: str
    route_rules: list[dict[str, str]] = field(default_factory=list)
    default_volume: str = ""
    volumes_root: str = "/Volumes"

    def __post_init__(self) -> None:
        if not self.mount_point:
            raise ValueError("mount_point must not be empty")
        for i, rule in enumerate(self.route_rules):
            for required in ("prefix", "volume", "target_subpath"):
                if required not in rule:
                    raise ValueError(
                        f"route_rules[{i}] is missing required key '{required}'"
                    )
            if not rule["prefix"].startswith("/"):
                raise ValueError(
                    f"route_rules[{i}]['prefix'] must start with '/'; "
                    f"got {rule['prefix']!r}"
                )

    def volume_root(self, volume: str) -> str:
        """Return the real filesystem root for a volume name."""
        return os.path.join(self.volumes_root, volume)


# ---------------------------------------------------------------------------
# OverlayFS
# ---------------------------------------------------------------------------


class OverlayFS(_FuseOperationsBase):
    """FUSE filesystem that overlays multiple APFS volumes as one namespace.

    Inherits from ``fuse.Operations`` (or its stand-in stub) to satisfy the
    fusepy interface.  All POSIX operations resolve the virtual path to a real
    path via :meth:`_resolve` and then delegate to the OS.

    Args:
        config: Routing and mount configuration.
    """

    def __init__(self, config: OverlayConfig) -> None:
        self.config = config
        logger.debug(
            "OverlayFS initialised — mount_point=%s  rules=%d",
            config.mount_point,
            len(config.route_rules),
        )

    # ------------------------------------------------------------------
    # Path resolution
    # ------------------------------------------------------------------

    def _resolve(self, path: str) -> str:
        """Map a virtual *path* to a real filesystem path.

        Resolution algorithm:

        1. Iterate ``route_rules`` in declaration order.
        2. For each rule, test whether *path* equals the rule's ``prefix``
           or starts with ``<prefix>/``.  The first match wins.
        3. Strip the matched prefix, join the remainder onto the volume's
           real root plus the rule's ``target_subpath``.
        4. If no rule matches, fall back to the ``default_volume``.

        Args:
            path: Virtual (overlay) path, always starting with ``/``.

        Returns:
            Absolute real filesystem path.

        Example:
            Given a rule ``{"prefix": "/projects", "volume": "DDRV904",
            "target_subpath": "projects"}`` and ``volumes_root="/Volumes"``,
            the virtual path ``/projects/foo/bar`` resolves to
            ``/Volumes/DDRV904/projects/foo/bar``.
        """
        for rule in self.config.route_rules:
            prefix: str = rule["prefix"]
            if path == prefix or path.startswith(prefix + "/"):
                remainder = path[len(prefix):]
                # remainder is either "" or starts with "/"
                subpath: str = rule["target_subpath"]
                real_root = self.config.volume_root(rule["volume"])
                if subpath:
                    real_root = os.path.join(real_root, subpath)
                # Append remainder (strip leading slash to avoid os.path.join
                # treating it as absolute and discarding real_root).
                real_path = (
                    os.path.join(real_root, remainder.lstrip("/"))
                    if remainder
                    else real_root
                )
                return os.path.normpath(real_path)

        # No rule matched — fall through to default volume.
        vol = self.config.default_volume
        if not vol:
            # Nowhere to go — return a path that will produce ENOENT.
            return os.path.join(self.config.volumes_root, "__unmapped__", path.lstrip("/"))
        real_root = self.config.volume_root(vol)
        return os.path.normpath(os.path.join(real_root, path.lstrip("/")))

    # ------------------------------------------------------------------
    # FUSE operation helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _errno_wrap(fn: Any, *args: Any, **kwargs: Any) -> Any:
        """Call *fn* and convert OSError to the appropriate FUSE errno."""
        try:
            return fn(*args, **kwargs)
        except OSError as exc:
            raise OSError(exc.errno, os.strerror(exc.errno or 0)) from exc

    # ------------------------------------------------------------------
    # FUSE operations
    # ------------------------------------------------------------------

    def getattr(self, path: str, fh: Optional[int] = None) -> dict[str, Any]:
        """Return stat-like dict for *path*.

        Args:
            path: Virtual path.
            fh: Optional open file handle (ignored; we re-stat by path).

        Returns:
            Dict with st_* keys compatible with the FUSE stat structure.

        Raises:
            OSError: With errno.ENOENT if the real path does not exist.
        """
        real = self._resolve(path)
        try:
            st = os.lstat(real)
        except OSError:
            raise OSError(errno.ENOENT, os.strerror(errno.ENOENT))
        return {
            "st_atime": st.st_atime,
            "st_ctime": st.st_ctime,
            "st_gid":   st.st_gid,
            "st_mode":  st.st_mode,
            "st_mtime": st.st_mtime,
            "st_nlink": st.st_nlink,
            "st_size":  st.st_size,
            "st_uid":   st.st_uid,
        }

    def readdir(self, path: str, fh: int) -> list[str]:
        """Return directory entries for *path*.

        Args:
            path: Virtual directory path.
            fh: Open directory handle (unused; we re-open by real path).

        Returns:
            List of entry names including ``.`` and ``..``.

        Raises:
            OSError: With errno.ENOENT if the directory does not exist.
        """
        real = self._resolve(path)
        try:
            entries = os.listdir(real)
        except OSError:
            raise OSError(errno.ENOENT, os.strerror(errno.ENOENT))
        return [".", ".."] + entries

    def open(self, path: str, flags: int) -> int:
        """Open *path* with *flags* and return a file descriptor.

        Args:
            path: Virtual file path.
            flags: Open flags (O_RDONLY, O_WRONLY, etc.).

        Returns:
            Integer file descriptor.
        """
        real = self._resolve(path)
        return self._errno_wrap(os.open, real, flags)

    def release(self, path: str, fh: int) -> None:
        """Close the file descriptor *fh*.

        Args:
            path: Virtual path (unused after open).
            fh: File descriptor to close.
        """
        os.close(fh)

    def read(self, path: str, size: int, offset: int, fh: int) -> bytes:
        """Read *size* bytes from *path* at *offset*.

        Args:
            path: Virtual file path (unused; we use *fh*).
            size: Maximum number of bytes to read.
            offset: Byte offset from the start of the file.
            fh: Open file descriptor.

        Returns:
            Bytes read (may be fewer than *size* at EOF).
        """
        os.lseek(fh, offset, os.SEEK_SET)
        return os.read(fh, size)

    def write(self, path: str, data: bytes, offset: int, fh: int) -> int:
        """Write *data* to *path* at *offset*.

        Args:
            path: Virtual file path (unused; we use *fh*).
            data: Bytes to write.
            offset: Byte offset from the start of the file.
            fh: Open file descriptor.

        Returns:
            Number of bytes written.
        """
        os.lseek(fh, offset, os.SEEK_SET)
        return os.write(fh, data)

    def create(self, path: str, mode: int, fi: Any = None) -> int:
        """Create a new file at *path* with *mode* and return a file descriptor.

        Args:
            path: Virtual destination path.
            mode: File permission bits.
            fi: FUSE file-info struct (unused in this implementation).

        Returns:
            Integer file descriptor for the newly created file.
        """
        real = self._resolve(path)
        return self._errno_wrap(
            os.open, real, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode
        )

    def mkdir(self, path: str, mode: int) -> None:
        """Create directory *path* with *mode*.

        Args:
            path: Virtual directory path to create.
            mode: Directory permission bits.
        """
        real = self._resolve(path)
        self._errno_wrap(os.mkdir, real, mode)

    def unlink(self, path: str) -> None:
        """Remove (delete) the file at *path*.

        Args:
            path: Virtual file path to remove.
        """
        real = self._resolve(path)
        self._errno_wrap(os.unlink, real)

    def rmdir(self, path: str) -> None:
        """Remove the empty directory at *path*.

        Args:
            path: Virtual directory path to remove.
        """
        real = self._resolve(path)
        self._errno_wrap(os.rmdir, real)

    def rename(self, old: str, new: str) -> None:
        """Rename *old* to *new*.

        Both paths must resolve to the same underlying volume; cross-volume
        renames are not supported and will raise EXDEV.

        Args:
            old: Virtual source path.
            new: Virtual destination path.

        Raises:
            OSError: With errno.EXDEV if the resolved paths span volumes.
        """
        real_old = self._resolve(old)
        real_new = self._resolve(new)
        # Detect cross-volume rename attempts.
        vol_old = _extract_volume(real_old, self.config.volumes_root)
        vol_new = _extract_volume(real_new, self.config.volumes_root)
        if vol_old != vol_new:
            raise OSError(errno.EXDEV, "Cross-device link — cross-volume rename not supported")
        self._errno_wrap(os.rename, real_old, real_new)

    def statfs(self, path: str) -> dict[str, int]:
        """Return filesystem statistics for the volume backing *path*.

        Args:
            path: Virtual path (used only to determine which volume to query).

        Returns:
            Dict with f_* keys compatible with the FUSE statvfs structure.
        """
        real = self._resolve(path)
        # Walk up until we find a real directory to statvfs on.
        check = real
        while check != "/" and not os.path.exists(check):
            check = os.path.dirname(check)
        try:
            stv = os.statvfs(check)
        except OSError:
            # Volume not mounted — return zeroed stats rather than crashing.
            return {
                "f_bsize": 4096, "f_frsize": 4096,
                "f_blocks": 0, "f_bfree": 0, "f_bavail": 0,
                "f_files": 0, "f_ffree": 0, "f_favail": 0,
                "f_flag": 0, "f_namemax": 255,
            }
        return {
            "f_bsize":   stv.f_bsize,
            "f_frsize":  stv.f_frsize,
            "f_blocks":  stv.f_blocks,
            "f_bfree":   stv.f_bfree,
            "f_bavail":  stv.f_bavail,
            "f_files":   stv.f_files,
            "f_ffree":   stv.f_ffree,
            "f_favail":  stv.f_favail,
            "f_flag":    stv.f_flag,
            "f_namemax": stv.f_namemax,
        }

    # ------------------------------------------------------------------
    # Mount / unmount
    # ------------------------------------------------------------------

    def mount(self) -> None:
        """Mount the overlay filesystem and enter the FUSE event loop.

        This call blocks until the filesystem is unmounted (e.g. via
        :meth:`unmount`, ``umount``, or ``diskutil unmount``).

        Raises:
            RuntimeError: If fusepy is not installed.
        """
        if not _FUSE_AVAILABLE:
            raise RuntimeError(
                "fusepy is not installed.  Install it with: pip install fusepy"
            )
        logger.info("Mounting OverlayFS at %s", self.config.mount_point)
        Path(self.config.mount_point).mkdir(parents=True, exist_ok=True)
        # fuse.FUSE blocks; foreground=True keeps logging to stdout.
        fuse.FUSE(  # type: ignore[name-defined]
            self,
            self.config.mount_point,
            foreground=True,
            nothreads=False,
            allow_other=False,
        )

    def unmount(self) -> None:
        """Unmount the overlay filesystem.

        Uses ``diskutil unmount`` on macOS and ``fusermount -u`` elsewhere.
        Safe to call even if not currently mounted.
        """
        mp = self.config.mount_point
        logger.info("Unmounting OverlayFS at %s", mp)
        if os.uname().sysname == "Darwin":
            cmd = ["diskutil", "unmount", mp]
        else:
            cmd = ["fusermount", "-u", mp]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            logger.warning("unmount exited %d: %s", result.returncode, result.stderr.strip())


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _extract_volume(real_path: str, volumes_root: str) -> str:
    """Return the volume component of *real_path* rooted at *volumes_root*.

    Args:
        real_path: Absolute real filesystem path.
        volumes_root: Parent directory of volumes (e.g. ``"/Volumes"``).

    Returns:
        Volume name string, or empty string if *real_path* is not under
        *volumes_root*.

    Example:
        ``_extract_volume("/Volumes/DDRV904/projects/foo", "/Volumes")``
        returns ``"DDRV904"``.
    """
    try:
        rel = Path(real_path).relative_to(volumes_root)
        return rel.parts[0] if rel.parts else ""
    except ValueError:
        return ""


# ---------------------------------------------------------------------------
# Performance measurement
# ---------------------------------------------------------------------------


def measure_performance(
    overlay_path: str,
    direct_path: str,
    ops: int = 1000,
) -> dict[str, Any]:
    """Time file create/read/delete on two paths and return a comparison dict.

    This is a **stub benchmark** intended for exploratory use.  It creates *ops*
    small temporary files on each path, measures wall-clock latency, and returns
    aggregated results.  It does NOT require FUSE or macFUSE to be installed —
    both *overlay_path* and *direct_path* can be ordinary directories, which is
    how the test suite exercises this function.

    Args:
        overlay_path: Path to the FUSE-mounted overlay (or any directory).
        direct_path: Path to the raw APFS volume directory for comparison.
        ops: Number of file create/read/delete cycles to run on each path.

    Returns:
        Dict with the following keys:

        * ``ops`` — number of operations per path.
        * ``overlay`` — sub-dict: ``total_s``, ``mean_us``, ``path``.
        * ``direct``  — sub-dict: ``total_s``, ``mean_us``, ``path``.
        * ``overhead_us`` — estimated per-operation overhead of the overlay
          (overlay.mean_us - direct.mean_us), or ``None`` if direct mean is 0.
        * ``note`` — human-readable summary string.

    Example::

        result = measure_performance("/mnt/devdrive/projects", "/Volumes/DDRV904/projects")
        print(result["overhead_us"])
    """
    payload = b"x" * 512  # 512-byte file content per operation

    def _run(base: str) -> float:
        """Return total wall-clock seconds for *ops* create/read/delete cycles."""
        Path(base).mkdir(parents=True, exist_ok=True)
        t0 = time.perf_counter()
        for i in range(ops):
            fp = os.path.join(base, f"_lfg_bench_{i}.tmp")
            # Create + write
            with open(fp, "wb") as fh:
                fh.write(payload)
            # Read
            with open(fp, "rb") as fh:
                _ = fh.read()
            # Delete
            os.unlink(fp)
        return time.perf_counter() - t0

    overlay_total = _run(overlay_path)
    direct_total = _run(direct_path)

    overlay_mean_us = (overlay_total / ops) * 1_000_000
    direct_mean_us = (direct_total / ops) * 1_000_000
    overhead_us: Optional[float] = (
        overlay_mean_us - direct_mean_us if direct_mean_us > 0 else None
    )

    note = (
        f"Overlay mean {overlay_mean_us:.1f} µs vs direct {direct_mean_us:.1f} µs "
        f"({'overhead N/A' if overhead_us is None else f'overhead {overhead_us:+.1f} µs'})"
    )
    logger.info(note)

    return {
        "ops": ops,
        "overlay": {
            "path":    overlay_path,
            "total_s": round(overlay_total, 6),
            "mean_us": round(overlay_mean_us, 3),
        },
        "direct": {
            "path":    direct_path,
            "total_s": round(direct_total, 6),
            "mean_us": round(direct_mean_us, 3),
        },
        "overhead_us": round(overhead_us, 3) if overhead_us is not None else None,
        "note": note,
    }

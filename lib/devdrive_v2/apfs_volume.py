"""DevDrive v2 APFS volume backend — thin wrappers around diskutil apfs.

All public functions return a VolumeResult and never raise for user-facing
operations.  Subprocess calls are isolated behind the module-level ``_run``
helper so tests can patch it without spawning real processes.

Byte-size convention: 1 GB = 1 000 000 000 bytes (SI), matching diskutil.
"""

from __future__ import annotations

import plistlib
import subprocess
from dataclasses import dataclass, field
from typing import Any, Optional


# ---------------------------------------------------------------------------
# Result type
# ---------------------------------------------------------------------------


@dataclass
class VolumeResult:
    """Outcome of an APFS volume operation.

    Attributes:
        success: True when the underlying command completed without error.
        message: Human-readable status or error description.
        data: Optional structured output extracted from the command's plist
              or text output.  Empty dict when not applicable.
    """

    success: bool
    message: str
    data: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Internal subprocess helper
# ---------------------------------------------------------------------------


def _run(args: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
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
# Internal utilities
# ---------------------------------------------------------------------------


def _gb_to_bytes(gb: float) -> int:
    """Convert gigabytes (SI) to bytes.

    Args:
        gb: Size in gigabytes.

    Returns:
        Equivalent size in bytes as an integer.
    """
    return int(gb * 1_000_000_000)


def _container_exists(container: str) -> bool:
    """Return True when *container* is a recognised disk identifier.

    Uses ``diskutil info`` to verify the identifier is valid; any non-zero
    exit code or exception is treated as "does not exist".

    Args:
        container: Disk identifier such as ``disk3``.

    Returns:
        True if diskutil recognises the identifier.
    """
    try:
        result = _run(["diskutil", "info", container])
        return result.returncode == 0
    except Exception:
        return False


def _volume_exists(name: str) -> bool:
    """Return True when *name* resolves to a known volume via diskutil.

    Args:
        name: Volume name or device identifier.

    Returns:
        True if diskutil can describe the volume.
    """
    try:
        result = _run(["diskutil", "info", name])
        return result.returncode == 0
    except Exception:
        return False


def _get_mount_point(name: str) -> Optional[str]:
    """Return the mount point of *name* by parsing the diskutil plist.

    Args:
        name: Volume name or device identifier.

    Returns:
        Mount point string, or None on any error.
    """
    try:
        result = _run(["diskutil", "info", "-plist", name])
        if result.returncode != 0 or not result.stdout:
            return None
        info: dict[str, Any] = plistlib.loads(result.stdout.encode())
        mp = info.get("MountPoint", "")
        return mp if mp else None
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def create_volume(
    name: str,
    quota_gb: float,
    reserve_gb: float = 0,
    container: str = "disk3",
) -> VolumeResult:
    """Create a new APFS volume in *container* with an optional quota and reserve.

    Calls::

        diskutil apfs addVolume <container> APFS <name> -quota <bytes> -role U
        # with -reserve <bytes> appended when reserve_gb > 0

    Args:
        name: Volume name.  Must be non-empty.
        quota_gb: Maximum space the volume may use, in GB (SI).  Must be > 0.
        reserve_gb: Space guaranteed to the volume, in GB.  Omitted when 0.
        container: APFS container disk identifier (e.g. ``disk3``).

    Returns:
        VolumeResult with success=True and data containing the diskutil output
        on success; success=False with a descriptive message on any failure.
    """
    # --- Input validation ---
    if not name or not name.strip():
        return VolumeResult(success=False, message="Volume name must not be empty.")
    if quota_gb <= 0:
        return VolumeResult(
            success=False,
            message=f"quota_gb must be positive; got {quota_gb}.",
        )
    if reserve_gb < 0:
        return VolumeResult(
            success=False,
            message=f"reserve_gb must not be negative; got {reserve_gb}.",
        )
    if not container or not container.strip():
        return VolumeResult(
            success=False, message="Container identifier must not be empty."
        )

    # --- Verify container is reachable ---
    if not _container_exists(container):
        return VolumeResult(
            success=False,
            message=f"Container '{container}' not found or not accessible.",
        )

    quota_bytes = _gb_to_bytes(quota_gb)
    args = [
        "diskutil",
        "apfs",
        "addVolume",
        container,
        "APFS",
        name,
        "-quota",
        str(quota_bytes),
        "-role",
        "U",
    ]
    if reserve_gb > 0:
        args += ["-reserve", str(_gb_to_bytes(reserve_gb))]

    try:
        result = _run(args)
        if result.returncode == 0:
            return VolumeResult(
                success=True,
                message=f"Volume '{name}' created in {container}.",
                data={"stdout": result.stdout, "stderr": result.stderr},
            )
        return VolumeResult(
            success=False,
            message=result.stderr.strip() or result.stdout.strip() or "diskutil returned non-zero.",
            data={"returncode": result.returncode},
        )
    except Exception as exc:
        return VolumeResult(success=False, message=str(exc))


def delete_volume(name: str) -> VolumeResult:
    """Delete an APFS volume by name.

    Verifies the volume exists via ``diskutil info`` before attempting deletion,
    then calls::

        diskutil apfs deleteVolume <name>

    Args:
        name: Volume name or device identifier to delete.

    Returns:
        VolumeResult indicating success or the reason for failure.
    """
    if not name or not name.strip():
        return VolumeResult(success=False, message="Volume name must not be empty.")

    if not _volume_exists(name):
        return VolumeResult(
            success=False,
            message=f"Volume '{name}' not found; nothing to delete.",
        )

    try:
        result = _run(["diskutil", "apfs", "deleteVolume", name])
        if result.returncode == 0:
            return VolumeResult(
                success=True,
                message=f"Volume '{name}' deleted.",
                data={"stdout": result.stdout, "stderr": result.stderr},
            )
        return VolumeResult(
            success=False,
            message=result.stderr.strip() or result.stdout.strip() or "diskutil returned non-zero.",
            data={"returncode": result.returncode},
        )
    except Exception as exc:
        return VolumeResult(success=False, message=str(exc))


def rename_volume(old_name: str, new_name: str) -> VolumeResult:
    """Rename an APFS volume.

    Calls::

        diskutil rename <old_name> <new_name>

    Args:
        old_name: Current volume name.
        new_name: Desired new name.  Must be non-empty.

    Returns:
        VolumeResult indicating success or the reason for failure.
    """
    if not old_name or not old_name.strip():
        return VolumeResult(success=False, message="old_name must not be empty.")
    if not new_name or not new_name.strip():
        return VolumeResult(success=False, message="new_name must not be empty.")

    try:
        result = _run(["diskutil", "rename", old_name, new_name])
        if result.returncode == 0:
            return VolumeResult(
                success=True,
                message=f"Volume '{old_name}' renamed to '{new_name}'.",
                data={"stdout": result.stdout, "stderr": result.stderr},
            )
        return VolumeResult(
            success=False,
            message=result.stderr.strip() or result.stdout.strip() or "diskutil returned non-zero.",
            data={"returncode": result.returncode},
        )
    except Exception as exc:
        return VolumeResult(success=False, message=str(exc))


def set_quota(name: str, quota_gb: float) -> VolumeResult:
    """Adjust the quota of an existing APFS volume.

    Uses the closest diskutil equivalent for quota adjustment::

        diskutil apfs resizeContainer <name> -quota <bytes>

    Args:
        name: Volume name or device identifier.
        quota_gb: New quota in GB (SI).  Must be > 0.

    Returns:
        VolumeResult indicating success or the reason for failure.
    """
    if not name or not name.strip():
        return VolumeResult(success=False, message="Volume name must not be empty.")
    if quota_gb <= 0:
        return VolumeResult(
            success=False,
            message=f"quota_gb must be positive; got {quota_gb}.",
        )

    quota_bytes = _gb_to_bytes(quota_gb)
    try:
        result = _run(
            ["diskutil", "apfs", "resizeContainer", name, "-quota", str(quota_bytes)]
        )
        if result.returncode == 0:
            return VolumeResult(
                success=True,
                message=f"Quota for '{name}' set to {quota_gb} GB.",
                data={"stdout": result.stdout, "stderr": result.stderr},
            )
        return VolumeResult(
            success=False,
            message=result.stderr.strip() or result.stdout.strip() or "diskutil returned non-zero.",
            data={"returncode": result.returncode},
        )
    except Exception as exc:
        return VolumeResult(success=False, message=str(exc))


def list_snapshots(name: str) -> VolumeResult:
    """List APFS snapshots on a volume.

    Calls::

        diskutil apfs listSnapshots <name>

    Parses the text output into a list of snapshot dicts, each containing
    at minimum ``name`` and ``date`` keys.  Lines that cannot be parsed are
    skipped.

    Args:
        name: Volume name or device identifier.

    Returns:
        VolumeResult with ``data["snapshots"]`` being a list of dicts on
        success; success=False on subprocess or validation failure.
    """
    if not name or not name.strip():
        return VolumeResult(success=False, message="Volume name must not be empty.")

    try:
        result = _run(["diskutil", "apfs", "listSnapshots", name])
        if result.returncode != 0:
            return VolumeResult(
                success=False,
                message=result.stderr.strip() or result.stdout.strip() or "diskutil returned non-zero.",
                data={"returncode": result.returncode},
            )
        snapshots = _parse_snapshot_output(result.stdout)
        return VolumeResult(
            success=True,
            message=f"Found {len(snapshots)} snapshot(s) on '{name}'.",
            data={"snapshots": snapshots, "raw": result.stdout},
        )
    except Exception as exc:
        return VolumeResult(success=False, message=str(exc))


def _parse_snapshot_output(output: str) -> list[dict[str, str]]:
    """Parse the text output of ``diskutil apfs listSnapshots``.

    diskutil snapshot lines look like::

        +-- Snapshot: com.apple.TimeMachine.2024-01-15-120000
        |   XID: 12345
        |   Created: 2024-01-15 12:00:00 +0000

    This parser captures ``Snapshot:`` and ``Created:`` values, emitting one
    dict per snapshot.  Unknown output formats are handled gracefully.

    Args:
        output: Raw stdout from diskutil.

    Returns:
        List of dicts with ``name`` and ``date`` keys.
    """
    snapshots: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in output.splitlines():
        stripped = line.strip()
        # Snapshot name line
        if "Snapshot:" in stripped:
            if current:
                snapshots.append(current)
            current = {"name": stripped.split("Snapshot:")[-1].strip(), "date": ""}
        # Created / date line
        elif "Created:" in stripped and current:
            current["date"] = stripped.split("Created:")[-1].strip()
    if current:
        snapshots.append(current)
    return snapshots


def take_snapshot(name: str) -> VolumeResult:
    """Create a local Time Machine snapshot on the volume's mount point.

    Resolves the mount point for *name* via ``diskutil info``, then calls::

        tmutil localsnapshot <mount_point>

    Args:
        name: Volume name or device identifier.

    Returns:
        VolumeResult indicating success or the reason for failure.
    """
    if not name or not name.strip():
        return VolumeResult(success=False, message="Volume name must not be empty.")

    mount_point = _get_mount_point(name)
    if mount_point is None:
        return VolumeResult(
            success=False,
            message=f"Could not determine mount point for '{name}'; "
            "volume may not be mounted.",
        )

    try:
        result = _run(["tmutil", "localsnapshot", mount_point])
        if result.returncode == 0:
            return VolumeResult(
                success=True,
                message=f"Snapshot taken on '{name}' at {mount_point}.",
                data={"stdout": result.stdout, "stderr": result.stderr},
            )
        return VolumeResult(
            success=False,
            message=result.stderr.strip() or result.stdout.strip() or "tmutil returned non-zero.",
            data={"returncode": result.returncode},
        )
    except Exception as exc:
        return VolumeResult(success=False, message=str(exc))


def get_container_info() -> VolumeResult:
    """Return structured information about all APFS containers and volumes.

    Calls::

        diskutil apfs list -plist

    Parses the plist and extracts container/volume metadata.

    Returns:
        VolumeResult with ``data["containers"]`` being a list of container
        dicts on success.  Each container dict contains a ``volumes`` list.
    """
    try:
        result = _run(["diskutil", "apfs", "list", "-plist"])
        if result.returncode != 0 or not result.stdout:
            return VolumeResult(
                success=False,
                message=result.stderr.strip() or "diskutil returned no output.",
                data={"returncode": result.returncode},
            )

        plist_data: dict[str, Any] = plistlib.loads(result.stdout.encode())
        containers_raw: list[dict[str, Any]] = plist_data.get("Containers", [])
        containers: list[dict[str, Any]] = []

        for container in containers_raw:
            volumes: list[dict[str, Any]] = []
            for vol in container.get("Volumes", []):
                volumes.append(
                    {
                        "name": vol.get("Name", ""),
                        "device": vol.get("DeviceIdentifier", ""),
                        "mount_point": vol.get("MountPoint", ""),
                        "role": vol.get("Roles", []),
                        "capacity_ceiling": vol.get("CapacityCeiling", 0),
                        "capacity_quota": vol.get("CapacityQuota", 0),
                    }
                )
            containers.append(
                {
                    "device": container.get("ContainerReference", ""),
                    "designation": container.get("Designation", ""),
                    "capacity_ceiling": container.get("CapacityCeiling", 0),
                    "capacity_free": container.get("CapacityFree", 0),
                    "volumes": volumes,
                }
            )

        return VolumeResult(
            success=True,
            message=f"Found {len(containers)} APFS container(s).",
            data={"containers": containers},
        )
    except Exception as exc:
        return VolumeResult(success=False, message=str(exc))


def get_volume_info(name: str) -> VolumeResult:
    """Return structured information about a single APFS volume.

    Calls::

        diskutil info -plist <name>

    Extracts mount_point, device identifier, total size, and free space.

    Args:
        name: Volume name or device identifier.

    Returns:
        VolumeResult with ``data`` containing ``mount_point``, ``device``,
        ``size_bytes``, and ``free_bytes`` on success; success=False otherwise.
    """
    if not name or not name.strip():
        return VolumeResult(success=False, message="Volume name must not be empty.")

    try:
        result = _run(["diskutil", "info", "-plist", name])
        if result.returncode != 0 or not result.stdout:
            return VolumeResult(
                success=False,
                message=result.stderr.strip() or f"diskutil could not find volume '{name}'.",
                data={"returncode": result.returncode},
            )

        info: dict[str, Any] = plistlib.loads(result.stdout.encode())
        data: dict[str, Any] = {
            "mount_point": info.get("MountPoint", ""),
            "device": info.get("DeviceIdentifier", ""),
            "size_bytes": info.get("TotalSize", info.get("Size", 0)),
            "free_bytes": info.get(
                "FreeSpace",
                info.get("APFSContainerFree", 0),
            ),
            "volume_name": info.get("VolumeName", ""),
            "file_system": info.get("FilesystemType", info.get("Content", "")),
        }
        return VolumeResult(
            success=True,
            message=f"Volume info retrieved for '{name}'.",
            data=data,
        )
    except Exception as exc:
        return VolumeResult(success=False, message=str(exc))

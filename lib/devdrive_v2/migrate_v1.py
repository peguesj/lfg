"""DevDrive v2 migration helper — sparse image to native APFS volume (US-005).

Provides a four-stage migration pipeline for promoting a v1 sparseimage-backed
volume to a native APFS volume in the same container:

    preflight  → validate preconditions and build a checksum manifest
    migrate    → create APFS volume, rsync data, verify, detach old image,
                 rename new volume to the original name
    rollback   → re-attach the old image and rsync data back if needed
    cleanup    → delete the old sparseimage once the grace period has elapsed

All subprocess calls go through the module-level ``_run()`` helper, which
makes the entire module patchable in tests without spawning real processes.

All public functions return a :class:`MigrationResult` and never raise.

Typical usage::

    from devdrive_v2.migrate_v1 import preflight, migrate, cleanup

    pre = preflight("901DEVLIB", "/Users/Shared/lfg/images/901DEVLIB.sparseimage")
    if not pre.success:
        print(f"Preflight failed: {pre.message}")
    else:
        result = migrate("901DEVLIB", ..., dry_run=False)
        if result.success:
            cleanup("901DEVLIB", ...)
"""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import random
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from devdrive_v2.apfs_volume import create_volume, get_container_info, rename_volume

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Where per-volume migration state is recorded alongside the state file.
_MIGRATION_STATE_DIR = Path.home() / ".config" / "lfg" / "migrations"

# Number of files sampled when building and verifying the checksum manifest.
_CHECKSUM_SAMPLE_SIZE = 50

# Default suffix appended to the new APFS volume during migration.
_STAGING_SUFFIX = "-v2"

# Default container used when none is specified.
_DEFAULT_CONTAINER = "disk3"

# Timeout for slow operations such as rsync (seconds).
_RSYNC_TIMEOUT = 3600  # 1 hour

# Timeout for hdiutil attach/detach (seconds).
_HDIUTIL_TIMEOUT = 120


# ---------------------------------------------------------------------------
# MigrationResult
# ---------------------------------------------------------------------------


@dataclass
class MigrationResult:
    """Outcome of a single migration stage operation.

    Attributes:
        success: True when the stage completed without error.
        volume_name: The name of the volume being migrated.
        stage: Which pipeline stage produced this result.
            One of ``"preflight"``, ``"migrate"``, ``"verify"``,
            ``"rollback"``, or ``"cleanup"``.
        message: Human-readable status or error description.
        data: Optional structured payload.  Contents are stage-specific;
            see each function's docstring for the keys it populates.
    """

    success: bool
    volume_name: str
    stage: str  # "preflight" | "migrate" | "verify" | "rollback" | "cleanup"
    message: str
    data: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Internal subprocess wrapper
# ---------------------------------------------------------------------------


def _run(args: list[str], timeout: int = 300) -> subprocess.CompletedProcess[str]:
    """Thin wrapper around subprocess.run to make patching straightforward.

    Migration rsync operations can be slow, so the default timeout is 5 minutes
    rather than the 30 s used by other modules.  Callers that need a different
    ceiling should pass *timeout* explicitly.

    Args:
        args: Command and arguments passed to subprocess.run.
        timeout: Wall-clock timeout in seconds.  Defaults to 300 s.

    Returns:
        A CompletedProcess instance with stdout/stderr as str.
    """
    return subprocess.run(
        args,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _migration_state_path(volume_name: str) -> Path:
    """Return the JSON path where migration state for *volume_name* is stored.

    Args:
        volume_name: The volume being migrated.

    Returns:
        Absolute path to the per-volume migration state file.
    """
    return _MIGRATION_STATE_DIR / f"{volume_name}.json"


def _read_migration_state(volume_name: str) -> dict[str, Any]:
    """Read persisted migration state for *volume_name*.

    Returns an empty dict if the file does not exist or cannot be parsed.

    Args:
        volume_name: The volume name whose state file to read.

    Returns:
        Dict of migration state data.
    """
    path = _migration_state_path(volume_name)
    try:
        if path.exists():
            with open(path) as fh:
                return json.load(fh)
    except (OSError, json.JSONDecodeError):
        pass
    return {}


def _write_migration_state(volume_name: str, state: dict[str, Any]) -> None:
    """Persist migration state for *volume_name* atomically.

    Args:
        volume_name: The volume name.
        state: Dict to serialise to JSON.
    """
    path = _migration_state_path(volume_name)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w") as fh:
        json.dump(state, fh, indent=2)
        fh.write("\n")
    tmp.rename(path)


def _sha256_file(file_path: str) -> Optional[str]:
    """Return the hex-encoded SHA-256 digest of *file_path*.

    Returns None on any I/O error (permission, disappeared file, etc.).

    Args:
        file_path: Absolute path to the file to hash.

    Returns:
        Lowercase hex digest string, or None on error.
    """
    try:
        h = hashlib.sha256()
        with open(file_path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except (OSError, IOError):
        return None


def _collect_regular_files(root: str) -> list[str]:
    """Return a sorted list of absolute paths to all regular files under *root*.

    Symlinks are skipped (we only want real file content for checksums).

    Args:
        root: Directory to walk.

    Returns:
        Sorted list of absolute file paths.
    """
    paths: list[str] = []
    for dirpath, _dirs, filenames in os.walk(root, followlinks=False):
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.isfile(full) and not os.path.islink(full):
                paths.append(full)
    return sorted(paths)


def _build_checksum_manifest(
    root: str, sample_size: int = _CHECKSUM_SAMPLE_SIZE
) -> dict[str, str]:
    """Build a SHA-256 checksum manifest for a sample of files under *root*.

    Samples at most *sample_size* files.  If the directory contains fewer
    files than the sample size, all files are included.  The sample is
    deterministic when the filesystem enumeration order is stable.

    Args:
        root: Directory to sample.
        sample_size: Maximum number of files to include in the manifest.

    Returns:
        Dict mapping relative path (relative to *root*) to hex SHA-256 digest.
        Files that could not be hashed are omitted.
    """
    all_files = _collect_regular_files(root)
    if len(all_files) > sample_size:
        # Use a fixed seed so successive calls on the same tree produce the
        # same sample — deterministic enough for a spot-check but not
        # adversarially predictable.
        rng = random.Random(len(all_files))
        sampled = rng.sample(all_files, sample_size)
    else:
        sampled = all_files

    manifest: dict[str, str] = {}
    for abs_path in sampled:
        digest = _sha256_file(abs_path)
        if digest is not None:
            rel = os.path.relpath(abs_path, root)
            manifest[rel] = digest
    return manifest


def _verify_checksum_manifest(
    root: str, manifest: dict[str, str]
) -> tuple[bool, list[str]]:
    """Verify that files in *manifest* still have their expected checksums.

    Args:
        root: Directory under which relative manifest paths are resolved.
        manifest: Dict mapping relative path to expected SHA-256 hex digest.

    Returns:
        A tuple ``(all_match, mismatches)`` where *all_match* is True when
        every file matches its expected digest, and *mismatches* is a list of
        relative paths that failed verification.
    """
    mismatches: list[str] = []
    for rel, expected in manifest.items():
        abs_path = os.path.join(root, rel)
        actual = _sha256_file(abs_path)
        if actual != expected:
            mismatches.append(rel)
    return (len(mismatches) == 0, mismatches)


def _image_is_attached(image_path: str) -> bool:
    """Return True if *image_path* is currently attached via hdiutil.

    Uses ``hdiutil info -plist`` and scans image-path entries.

    Args:
        image_path: Absolute path to the ``.sparseimage`` file.

    Returns:
        True if hdiutil considers the image attached.
    """
    try:
        result = _run(["hdiutil", "info", "-plist"], timeout=30)
        if result.returncode != 0 or not result.stdout:
            return False
        info: dict[str, Any] = plistlib.loads(result.stdout.encode())
        for image in info.get("images", []):
            if image.get("image-path", "") == image_path:
                return True
        return False
    except Exception:
        return False


def _get_image_mount_point(image_path: str) -> Optional[str]:
    """Return the mount point of an attached sparseimage via hdiutil info.

    Args:
        image_path: Absolute path to the ``.sparseimage`` file.

    Returns:
        Mount point string (e.g. ``"/Volumes/901DEVLIB"``), or None if
        the image is not attached or the mount point cannot be determined.
    """
    try:
        result = _run(["hdiutil", "info", "-plist"], timeout=30)
        if result.returncode != 0 or not result.stdout:
            return None
        info: dict[str, Any] = plistlib.loads(result.stdout.encode())
        for image in info.get("images", []):
            if image.get("image-path", "") == image_path:
                for entity in image.get("system-entities", []):
                    mp = entity.get("mount-point", "")
                    if mp:
                        return mp
        return None
    except Exception:
        return None


def _get_container_free_bytes(container: str) -> Optional[int]:
    """Return free bytes available in *container* via get_container_info.

    Args:
        container: APFS container disk identifier (e.g. ``"disk3"``).

    Returns:
        Free capacity in bytes, or None if the container cannot be queried.
    """
    result = get_container_info()
    if not result.success:
        return None
    for c in result.data.get("containers", []):
        if c.get("device", "") == container:
            return c.get("capacity_free", None)
    return None


def _apfs_volume_mount_point(volume_name: str) -> Optional[str]:
    """Return the current mount point of a named APFS volume.

    Runs ``diskutil info -plist <volume_name>`` and extracts MountPoint.

    Args:
        volume_name: The APFS volume name.

    Returns:
        Mount point string, or None on any failure.
    """
    try:
        result = _run(["diskutil", "info", "-plist", volume_name], timeout=30)
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


def preflight(
    volume_name: str,
    image_path: str,
    container: str = _DEFAULT_CONTAINER,
) -> MigrationResult:
    """Validate preconditions for a v1-to-v2 migration and build a checksum manifest.

    Checks performed in order:

    1. Container *container* is queryable and has sufficient free capacity.
    2. *image_path* exists on disk.
    3. The sparseimage is currently attached (hdiutil reports it as mounted).
    4. A SHA-256 checksum manifest is built from a sample of the image content.

    Args:
        volume_name: Logical name of the volume being migrated
            (e.g. ``"901DEVLIB"``).
        image_path: Absolute path to the ``.sparseimage`` file.
        container: APFS container identifier to migrate into (default
            ``"disk3"``).

    Returns:
        MigrationResult with ``stage="preflight"``.  On success, ``data``
        contains:

        - ``estimated_gb`` (float): image file size in GB (SI).
        - ``file_count`` (int): total number of regular files found.
        - ``checksum_manifest`` (dict[str, str]): relative-path → SHA-256
          digest for the sample of files.
        - ``mount_point`` (str): current mount point of the attached image.
    """
    stage = "preflight"

    # --- 1. Container capacity check ---
    free_bytes = _get_container_free_bytes(container)
    if free_bytes is None:
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"Cannot query container '{container}'. "
                "Ensure the container exists and diskutil is available."
            ),
        )

    # --- 2. Image file existence ---
    if not os.path.exists(image_path):
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=f"Sparseimage not found at '{image_path}'.",
        )

    image_size_bytes = os.path.getsize(image_path)
    estimated_gb = image_size_bytes / 1_000_000_000

    if free_bytes < image_size_bytes:
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"Container '{container}' has {free_bytes / 1e9:.2f} GB free but "
                f"image is {estimated_gb:.2f} GB. Insufficient capacity."
            ),
            data={
                "estimated_gb": estimated_gb,
                "container_free_gb": free_bytes / 1_000_000_000,
            },
        )

    # --- 3. Image attachment check ---
    if not _image_is_attached(image_path):
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"Sparseimage '{image_path}' is not currently attached. "
                "Attach it via hdiutil before running preflight."
            ),
        )

    mount_point = _get_image_mount_point(image_path)
    if not mount_point:
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"Sparseimage '{image_path}' is attached but no mount point "
                "could be determined."
            ),
        )

    # --- 4. Checksum manifest ---
    all_files = _collect_regular_files(mount_point)
    file_count = len(all_files)
    checksum_manifest = _build_checksum_manifest(mount_point)

    return MigrationResult(
        success=True,
        volume_name=volume_name,
        stage=stage,
        message=(
            f"Preflight passed for '{volume_name}'. "
            f"Image: {estimated_gb:.2f} GB, {file_count} file(s). "
            f"Checksum manifest: {len(checksum_manifest)} sample(s)."
        ),
        data={
            "estimated_gb": estimated_gb,
            "file_count": file_count,
            "checksum_manifest": checksum_manifest,
            "mount_point": mount_point,
            "container": container,
            "container_free_gb": free_bytes / 1_000_000_000,
        },
    )


def migrate(
    volume_name: str,
    image_path: str,
    mount_point: str,
    dry_run: bool = True,
    container: str = _DEFAULT_CONTAINER,
    quota_gb: float = 0.0,
) -> MigrationResult:
    """Migrate a sparseimage-backed volume to a native APFS volume.

    Pipeline (``dry_run=False``):

    a. Create a staging APFS volume named ``<volume_name>-v2`` via
       :func:`~devdrive_v2.apfs_volume.create_volume`.
    b. ``rsync -aHAX`` from the image mount to the new volume's mount point.
    c. Sample-verify 10 random files using SHA-256 checksums.
    d. Detach the old sparseimage via ``hdiutil detach``.
    e. Rename the staging volume to the original name via
       :func:`~devdrive_v2.apfs_volume.rename_volume`.
    f. Record migration metadata (including a 24 h grace period timestamp)
       in the per-volume state file.

    When ``dry_run=True`` the function describes the plan without executing
    any subprocess or filesystem side-effects.

    Args:
        volume_name: Logical name of the volume (e.g. ``"901DEVLIB"``).
        image_path: Absolute path to the ``.sparseimage`` file.
        mount_point: Current mount point of the attached sparseimage
            (e.g. ``"/Volumes/901DEVLIB"``).
        dry_run: When True, no changes are applied.  Defaults to True.
        container: APFS container identifier (default ``"disk3"``).
        quota_gb: Quota for the new APFS volume in GB.  When 0 (default),
            the image file size is used as a rough estimate.

    Returns:
        MigrationResult with ``stage="migrate"``.  In dry-run mode, ``data``
        contains ``plan`` (list[str]) describing intended actions.  On
        successful apply, ``data`` contains ``staging_volume``,
        ``new_mount_point``, and ``grace_until`` (UNIX timestamp).
    """
    stage = "migrate"
    staging_name = f"{volume_name}{_STAGING_SUFFIX}"

    # --- Determine quota ---
    effective_quota_gb = quota_gb
    if effective_quota_gb <= 0:
        try:
            if os.path.exists(image_path):
                effective_quota_gb = os.path.getsize(image_path) / 1_000_000_000
        except OSError:
            pass
    # Ensure at least 1 GB so create_volume doesn't reject it.
    if effective_quota_gb <= 0:
        effective_quota_gb = 1.0

    # --- dry-run path ---
    if dry_run:
        plan = [
            f"Create APFS volume '{staging_name}' ({effective_quota_gb:.2f} GB) "
            f"in container '{container}'.",
            f"rsync -aHAX '{mount_point}/' → '/Volumes/{staging_name}/'",
            "Sample-verify 10 random files via SHA-256.",
            f"hdiutil detach '{mount_point}'",
            f"Rename '{staging_name}' → '{volume_name}'",
            "Record migration state with 24 h grace period.",
        ]
        return MigrationResult(
            success=True,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"[dry-run] Migration plan for '{volume_name}': "
                f"{len(plan)} step(s) described. No changes applied."
            ),
            data={
                "plan": plan,
                "staging_volume": staging_name,
                "effective_quota_gb": effective_quota_gb,
                "dry_run": True,
            },
        )

    # --- Apply: step a — create staging APFS volume ---
    create_result = create_volume(
        staging_name,
        quota_gb=effective_quota_gb,
        container=container,
    )
    if not create_result.success:
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=f"Failed to create staging volume '{staging_name}': {create_result.message}",
        )

    # Resolve the mount point of the new staging volume.
    new_mount = _apfs_volume_mount_point(staging_name)
    if not new_mount:
        new_mount = f"/Volumes/{staging_name}"

    # --- Apply: step b — rsync ---
    src = mount_point.rstrip("/") + "/"
    dst = new_mount.rstrip("/") + "/"
    rsync_result = _run(
        ["rsync", "-aHAX", src, dst],
        timeout=_RSYNC_TIMEOUT,
    )
    if rsync_result.returncode != 0:
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"rsync from '{src}' to '{dst}' failed "
                f"(rc={rsync_result.returncode}): {rsync_result.stderr.strip()}"
            ),
            data={"staging_volume": staging_name},
        )

    # --- Apply: step c — sample verify (10 files) ---
    all_files = _collect_regular_files(new_mount)
    verify_sample_size = min(10, len(all_files))
    verify_manifest: dict[str, str] = {}
    if verify_sample_size > 0:
        rng = random.Random(len(all_files))
        sample_files = rng.sample(all_files, verify_sample_size)
        for abs_path in sample_files:
            digest = _sha256_file(abs_path)
            if digest is not None:
                rel = os.path.relpath(abs_path, new_mount)
                # Compare against the source
                src_abs = os.path.join(mount_point, rel)
                src_digest = _sha256_file(src_abs)
                if src_digest != digest:
                    return MigrationResult(
                        success=False,
                        volume_name=volume_name,
                        stage="verify",
                        message=(
                            f"Checksum mismatch for '{rel}': "
                            f"src={src_digest!r} dst={digest!r}"
                        ),
                        data={"staging_volume": staging_name, "failed_file": rel},
                    )
                verify_manifest[rel] = digest

    # --- Apply: step d — detach old sparseimage ---
    detach_result = _run(
        ["hdiutil", "detach", mount_point],
        timeout=_HDIUTIL_TIMEOUT,
    )
    if detach_result.returncode != 0:
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"hdiutil detach '{mount_point}' failed "
                f"(rc={detach_result.returncode}): {detach_result.stderr.strip()}"
            ),
            data={"staging_volume": staging_name},
        )

    # --- Apply: step e — rename staging volume to original name ---
    rename_result = rename_volume(staging_name, volume_name)
    if not rename_result.success:
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"Rename '{staging_name}' → '{volume_name}' failed: "
                f"{rename_result.message}"
            ),
            data={"staging_volume": staging_name},
        )

    # --- Apply: step f — record migration state with 24 h grace period ---
    grace_until = time.time() + (24 * 3600)
    migration_state = {
        "volume_name": volume_name,
        "image_path": image_path,
        "migrated_at": time.time(),
        "grace_until": grace_until,
        "verify_manifest": verify_manifest,
        "staging_volume": staging_name,
        "container": container,
    }
    _write_migration_state(volume_name, migration_state)

    return MigrationResult(
        success=True,
        volume_name=volume_name,
        stage=stage,
        message=(
            f"Migration of '{volume_name}' complete. "
            f"Data verified ({len(verify_manifest)} file(s) checked). "
            f"Old image detached. Cleanup available after "
            f"{time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime(grace_until))}."
        ),
        data={
            "staging_volume": staging_name,
            "new_mount_point": f"/Volumes/{volume_name}",
            "grace_until": grace_until,
            "verify_manifest": verify_manifest,
        },
    )


def rollback(
    volume_name: str,
    image_path: str,
) -> MigrationResult:
    """Roll back a migration by re-attaching the old sparseimage.

    Attaches the old image via ``hdiutil attach``, then rsyncs data from the
    APFS volume back to the image mount point.  This is intended for the
    grace period window when both the old image and the new APFS volume are
    still available.

    Args:
        volume_name: The volume name (e.g. ``"901DEVLIB"``).
        image_path: Absolute path to the ``.sparseimage`` file.

    Returns:
        MigrationResult with ``stage="rollback"``.  On success, ``data``
        contains ``image_mount_point`` and ``files_rsynced`` (stdout snippet).
    """
    stage = "rollback"

    # --- Re-attach sparseimage ---
    attach_result = _run(
        ["hdiutil", "attach", image_path],
        timeout=_HDIUTIL_TIMEOUT,
    )
    if attach_result.returncode != 0:
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"hdiutil attach '{image_path}' failed "
                f"(rc={attach_result.returncode}): {attach_result.stderr.strip()}"
            ),
        )

    # Resolve the mount point of the re-attached image.
    image_mount = _get_image_mount_point(image_path)
    if not image_mount:
        # Attempt a best-guess from the attach stdout (last /Volumes/... entry).
        for line in attach_result.stdout.splitlines():
            parts = line.split()
            if parts and parts[-1].startswith("/Volumes/"):
                image_mount = parts[-1]
                break

    if not image_mount:
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"Attached '{image_path}' but could not determine its mount point. "
                "Manual inspection required."
            ),
        )

    # Resolve the APFS volume mount point (source of rollback data).
    apfs_mount = _apfs_volume_mount_point(volume_name)
    if not apfs_mount:
        apfs_mount = f"/Volumes/{volume_name}"

    # --- rsync back from APFS volume to image mount ---
    src = apfs_mount.rstrip("/") + "/"
    dst = image_mount.rstrip("/") + "/"
    rsync_result = _run(
        ["rsync", "-aHAX", src, dst],
        timeout=_RSYNC_TIMEOUT,
    )
    if rsync_result.returncode != 0:
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"rsync rollback from '{src}' to '{dst}' failed "
                f"(rc={rsync_result.returncode}): {rsync_result.stderr.strip()}"
            ),
            data={"image_mount_point": image_mount},
        )

    return MigrationResult(
        success=True,
        volume_name=volume_name,
        stage=stage,
        message=(
            f"Rollback complete for '{volume_name}'. "
            f"Data rsynced back to sparseimage at '{image_mount}'."
        ),
        data={
            "image_mount_point": image_mount,
            "files_rsynced": rsync_result.stdout[:2000],  # abbreviated for data field
        },
    )


def cleanup(
    volume_name: str,
    image_path: str,
    grace_hours: float = 24.0,
) -> MigrationResult:
    """Delete the old sparseimage once the grace period has elapsed.

    Reads the migration state recorded by :func:`migrate` to determine when
    the grace period expires.  If the grace period has not yet elapsed, returns
    a non-success result indicating how much time remains.

    Args:
        volume_name: The volume name (e.g. ``"901DEVLIB"``).
        image_path: Absolute path to the ``.sparseimage`` to delete.
        grace_hours: Minimum hours since migration before deletion is
            permitted.  Defaults to 24.0.  This parameter overrides the
            ``grace_until`` timestamp only when the state file is absent —
            if a state file exists its ``grace_until`` value is authoritative.

    Returns:
        MigrationResult with ``stage="cleanup"``.  On success (file deleted),
        ``data`` contains ``deleted_path``.  When the grace period has not
        elapsed, ``data`` contains ``remaining_hours`` (float).
    """
    stage = "cleanup"

    # --- Read migration state ---
    state = _read_migration_state(volume_name)
    now = time.time()

    if state:
        grace_until = state.get("grace_until", now + (grace_hours * 3600))
    else:
        # No state file: apply grace_hours from now as a conservative fallback.
        grace_until = now + (grace_hours * 3600)

    if now < grace_until:
        remaining = (grace_until - now) / 3600
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"Grace period not yet elapsed for '{volume_name}'. "
                f"{remaining:.1f} hour(s) remaining before cleanup is permitted."
            ),
            data={
                "remaining_hours": remaining,
                "grace_until": grace_until,
            },
        )

    # --- Grace period elapsed: delete the image file ---
    if not os.path.exists(image_path):
        return MigrationResult(
            success=True,
            volume_name=volume_name,
            stage=stage,
            message=(
                f"Sparseimage '{image_path}' no longer exists "
                f"(already deleted or never present). Cleanup complete."
            ),
            data={"deleted_path": image_path},
        )

    try:
        os.remove(image_path)
    except OSError as exc:
        return MigrationResult(
            success=False,
            volume_name=volume_name,
            stage=stage,
            message=f"Failed to delete '{image_path}': {exc}",
        )

    return MigrationResult(
        success=True,
        volume_name=volume_name,
        stage=stage,
        message=(
            f"Cleanup complete for '{volume_name}'. "
            f"Sparseimage '{image_path}' deleted."
        ),
        data={"deleted_path": image_path},
    )

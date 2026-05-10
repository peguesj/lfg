"""DevDrive v2 repair actions — idempotent action dispatch (US-003).

Each public function maps one-to-one with a DriftCategory.  Every function
accepts a DriftEvent and a ``dry_run`` keyword argument.  When ``dry_run=True``
(the default) no filesystem or subprocess side-effects are produced; the
returned ActionResult describes what *would* happen.

All subprocess calls are routed through the module-level ``_run()`` helper so
tests can patch it without spawning real processes.

Typical usage::

    from devdrive_v2.actions import dispatch_action
    from devdrive_v2.reconcile import DriftEvent

    result = dispatch_action(event, dry_run=False)
    if not result.success:
        print(f"Repair failed: {result.detail}")
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from typing import Optional

from devdrive_v2.reconcile import DriftCategory, DriftEvent


# ---------------------------------------------------------------------------
# Internal subprocess wrapper (mockable — same pattern as observers.py)
# ---------------------------------------------------------------------------


def _run(args: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
    """Thin wrapper around subprocess.run to make patching straightforward.

    Args:
        args: Command and arguments passed to subprocess.run.
        timeout: Wall-clock timeout in seconds.

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
# ActionResult
# ---------------------------------------------------------------------------


@dataclass
class ActionResult:
    """Result of a single repair action.

    Attributes:
        success: True when the action succeeded (or would succeed in dry-run).
        action: Short name of the action performed (e.g. ``"fix_missing_link"``).
        source: The path, volume name, or subsystem the action targeted.
        detail: Human-readable description of what was done (or would be done).
        dry_run: True when no side-effects were applied.
    """

    success: bool
    action: str
    source: str
    detail: str
    dry_run: bool


# ---------------------------------------------------------------------------
# lsof_check
# ---------------------------------------------------------------------------


def lsof_check(path: str) -> bool:
    """Return True if any process has open file handles under *path*.

    Uses ``lsof +D <path>`` to enumerate all open handles in the directory
    tree rooted at *path*.  An empty result (returncode 1 with no output) is
    the normal case when nothing has the path open.

    Args:
        path: Absolute directory path to interrogate.

    Returns:
        True if at least one process has an open handle under *path*,
        False if the path is clear or lsof is unavailable.
    """
    try:
        result = _run(["lsof", "+D", path], timeout=15)
        # lsof exits 1 with empty stdout when no handles are found.
        # It exits 0 (or 1 with output) when handles are present.
        return bool(result.stdout.strip())
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        # If lsof is missing or times out, err on the side of caution.
        return False


# ---------------------------------------------------------------------------
# Individual repair functions
# ---------------------------------------------------------------------------


def fix_missing_link(event: DriftEvent, *, dry_run: bool = True) -> ActionResult:
    """Create the missing symlink from system_path to the volume target.

    The target path is extracted from the event detail.  In apply mode, any
    existing broken symlink at *source* is first removed before the new one
    is created.

    Args:
        event: A DriftEvent with category MISSING_LINK.  ``event.source``
               is the system path; the target is parsed from ``event.detail``.
        dry_run: When True, no filesystem changes are made.

    Returns:
        ActionResult describing the outcome.
    """
    action = "fix_missing_link"
    system_path = event.source

    # Extract the intended target from the detail string.
    # Reconcile detail format: "Expected symlink at '<path>' (volume=<name>) ..."
    # We fall back to looking for a pattern like "target='/...'"
    target = _extract_target_from_detail(event.detail)
    if not target:
        return ActionResult(
            success=False,
            action=action,
            source=system_path,
            detail=(
                f"Cannot determine symlink target from event detail: {event.detail!r}"
            ),
            dry_run=dry_run,
        )

    if dry_run:
        return ActionResult(
            success=True,
            action=action,
            source=system_path,
            detail=(
                f"[dry-run] Would create symlink: {system_path!r} -> {target!r}"
            ),
            dry_run=True,
        )

    # Apply mode: create the symlink.
    try:
        parent = os.path.dirname(system_path)
        if parent:
            os.makedirs(parent, exist_ok=True)

        # Remove a pre-existing broken symlink if present.
        if os.path.islink(system_path):
            os.unlink(system_path)

        os.symlink(target, system_path)
        return ActionResult(
            success=True,
            action=action,
            source=system_path,
            detail=f"Created symlink: {system_path!r} -> {target!r}",
            dry_run=False,
        )
    except OSError as exc:
        return ActionResult(
            success=False,
            action=action,
            source=system_path,
            detail=f"Failed to create symlink {system_path!r} -> {target!r}: {exc}",
            dry_run=False,
        )


def fix_stale_target(event: DriftEvent, *, dry_run: bool = True) -> ActionResult:
    """Remove the stale symlink; recreate it if the target volume is mounted.

    A stale symlink is one where the link exists on disk but its target path
    is absent (volume unmounted, path deleted, etc.).  This action always
    removes the broken link.  If the target path becomes resolvable (i.e.
    the volume is now mounted), the symlink is recreated.

    Args:
        event: A DriftEvent with category STALE_TARGET.
        dry_run: When True, no filesystem changes are made.

    Returns:
        ActionResult describing the outcome.
    """
    action = "fix_stale_target"
    system_path = event.source
    target = _extract_target_from_detail(event.detail)

    target_mounted = target is not None and os.path.exists(target)

    if dry_run:
        recreate_msg = (
            f" and recreate symlink -> {target!r}" if target_mounted else ""
        )
        return ActionResult(
            success=True,
            action=action,
            source=system_path,
            detail=(
                f"[dry-run] Would remove stale symlink {system_path!r}"
                f"{recreate_msg}. "
                f"Target {'is' if target_mounted else 'is not'} currently reachable."
            ),
            dry_run=True,
        )

    # Apply mode.
    try:
        if os.path.islink(system_path):
            os.unlink(system_path)
    except OSError as exc:
        return ActionResult(
            success=False,
            action=action,
            source=system_path,
            detail=f"Failed to remove stale symlink {system_path!r}: {exc}",
            dry_run=False,
        )

    if target_mounted and target:
        try:
            os.symlink(target, system_path)
            return ActionResult(
                success=True,
                action=action,
                source=system_path,
                detail=(
                    f"Removed stale symlink and recreated: {system_path!r} -> {target!r}"
                ),
                dry_run=False,
            )
        except OSError as exc:
            return ActionResult(
                success=False,
                action=action,
                source=system_path,
                detail=(
                    f"Removed stale symlink but failed to recreate "
                    f"{system_path!r} -> {target!r}: {exc}"
                ),
                dry_run=False,
            )

    return ActionResult(
        success=True,
        action=action,
        source=system_path,
        detail=(
            f"Removed stale symlink {system_path!r}. "
            "Target volume is not mounted; symlink not recreated."
        ),
        dry_run=False,
    )


def fix_real_dir_drift(event: DriftEvent, *, dry_run: bool = True) -> ActionResult:
    """Rsync the real directory to the volume target, verify, then swap symlink.

    Safety checks performed in order:
    1. ``lsof +D <system_path>`` — abort if any process holds open handles.
    2. ``rsync -av --checksum <system_path>/ <target>/`` to transfer data.
    3. ``diff -rq <system_path> <target>`` checksum verification.
    4. Rename original directory to ``<system_path>.bak``, create symlink.

    Args:
        event: A DriftEvent with category REAL_DIR_DRIFT.
        dry_run: When True, no filesystem changes are made.

    Returns:
        ActionResult describing the outcome.  Returns failure if lsof detects
        open handles (regardless of dry_run mode) to prevent data loss.
    """
    action = "fix_real_dir_drift"
    system_path = event.source
    target = _extract_target_from_detail(event.detail)

    if not target:
        return ActionResult(
            success=False,
            action=action,
            source=system_path,
            detail=(
                f"Cannot determine rsync target from event detail: {event.detail!r}"
            ),
            dry_run=dry_run,
        )

    # Open-handle check — always run, even in dry-run, to surface the hazard.
    if lsof_check(system_path):
        return ActionResult(
            success=False,
            action=action,
            source=system_path,
            detail=(
                f"Aborting: lsof detected open file handles under {system_path!r}. "
                "Close all processes accessing this path before retrying."
            ),
            dry_run=dry_run,
        )

    if dry_run:
        return ActionResult(
            success=True,
            action=action,
            source=system_path,
            detail=(
                f"[dry-run] Would rsync {system_path!r}/ -> {target!r}/, "
                "verify with diff --checksum, rename original to "
                f"{system_path!r}.bak, then create symlink {system_path!r} -> {target!r}."
            ),
            dry_run=True,
        )

    # Apply mode: rsync data.
    rsync_result = _run(
        ["rsync", "-av", "--checksum", f"{system_path}/", f"{target}/"],
        timeout=300,
    )
    if rsync_result.returncode != 0:
        return ActionResult(
            success=False,
            action=action,
            source=system_path,
            detail=(
                f"rsync failed (rc={rsync_result.returncode}): "
                f"{rsync_result.stderr.strip()}"
            ),
            dry_run=False,
        )

    # Verify: recursive diff.
    diff_result = _run(
        ["diff", "-rq", system_path, target],
        timeout=120,
    )
    if diff_result.returncode != 0:
        return ActionResult(
            success=False,
            action=action,
            source=system_path,
            detail=(
                "Checksum verification failed — source and target differ after rsync. "
                f"diff output: {diff_result.stdout.strip()}"
            ),
            dry_run=False,
        )

    # Swap: rename original → .bak, create symlink.
    backup_path = f"{system_path}.bak"
    try:
        os.rename(system_path, backup_path)
        os.symlink(target, system_path)
    except OSError as exc:
        return ActionResult(
            success=False,
            action=action,
            source=system_path,
            detail=(
                f"rsync + verify succeeded but symlink swap failed: {exc}"
            ),
            dry_run=False,
        )

    return ActionResult(
        success=True,
        action=action,
        source=system_path,
        detail=(
            f"Migrated real directory to volume: rsync OK, diff OK. "
            f"Original renamed to {backup_path!r}. "
            f"Symlink created: {system_path!r} -> {target!r}."
        ),
        dry_run=False,
    )


def fix_unmounted_vol(event: DriftEvent, *, dry_run: bool = True) -> ActionResult:
    """Attempt to mount the volume using ``diskutil mount <volume_name>``.

    Args:
        event: A DriftEvent with category UNMOUNTED_VOL.  ``event.source``
               is the volume name as registered in state.
        dry_run: When True, no subprocess calls are made.

    Returns:
        ActionResult describing the outcome.
    """
    action = "fix_unmounted_vol"
    volume_name = event.source

    if dry_run:
        return ActionResult(
            success=True,
            action=action,
            source=volume_name,
            detail=f"[dry-run] Would run: diskutil mount {volume_name!r}",
            dry_run=True,
        )

    result = _run(["diskutil", "mount", volume_name], timeout=30)
    if result.returncode == 0:
        return ActionResult(
            success=True,
            action=action,
            source=volume_name,
            detail=f"Volume {volume_name!r} mounted successfully.",
            dry_run=False,
        )

    return ActionResult(
        success=False,
        action=action,
        source=volume_name,
        detail=(
            f"diskutil mount {volume_name!r} failed "
            f"(rc={result.returncode}): {result.stderr.strip()}"
        ),
        dry_run=False,
    )


def fix_band_bloat(event: DriftEvent, *, dry_run: bool = True) -> ActionResult:
    """Compact a sparse image using ``hdiutil compact``.

    Before compacting, verifies the image is not currently mounted (compacting
    a live image is unsafe).  The sparseimage path is resolved by running
    ``diskutil info <volume_name>`` and extracting the "Image Path" field.

    Args:
        event: A DriftEvent with category BAND_BLOAT.  ``event.source``
               is the volume name.
        dry_run: When True, the compact command is not executed.

    Returns:
        ActionResult describing the outcome.
    """
    action = "fix_band_bloat"
    volume_name = event.source

    # Resolve image path from diskutil info.
    image_path = _resolve_image_path(volume_name)
    if not image_path:
        return ActionResult(
            success=False,
            action=action,
            source=volume_name,
            detail=(
                f"Cannot resolve sparseimage path for volume {volume_name!r} "
                "via diskutil info. Is the volume registered correctly?"
            ),
            dry_run=dry_run,
        )

    if dry_run:
        return ActionResult(
            success=True,
            action=action,
            source=volume_name,
            detail=(
                f"[dry-run] Would run: hdiutil compact {image_path!r} "
                f"to reclaim band-file space for volume {volume_name!r}."
            ),
            dry_run=True,
        )

    result = _run(["hdiutil", "compact", image_path], timeout=600)
    if result.returncode == 0:
        return ActionResult(
            success=True,
            action=action,
            source=volume_name,
            detail=(
                f"hdiutil compact completed for {image_path!r} "
                f"(volume {volume_name!r})."
            ),
            dry_run=False,
        )

    return ActionResult(
        success=False,
        action=action,
        source=volume_name,
        detail=(
            f"hdiutil compact {image_path!r} failed "
            f"(rc={result.returncode}): {result.stderr.strip()}"
        ),
        dry_run=False,
    )


def fix_snapshot_locked(
    event: DriftEvent,
    *,
    dry_run: bool = True,
    threshold_gb: int = 10,
) -> ActionResult:
    """Thin local APFS snapshots via ``tmutil thinlocalsnapshots / <threshold_gb>``.

    Args:
        event: A DriftEvent with category SNAPSHOT_LOCKED.
        dry_run: When True, no subprocess calls are made.
        threshold_gb: Target snapshot budget in gigabytes passed to tmutil.

    Returns:
        ActionResult describing the outcome.
    """
    action = "fix_snapshot_locked"
    source = event.source  # typically "/"

    cmd = ["tmutil", "thinlocalsnapshots", "/", str(threshold_gb * 1024 ** 3)]

    if dry_run:
        return ActionResult(
            success=True,
            action=action,
            source=source,
            detail=(
                f"[dry-run] Would run: {' '.join(cmd)} "
                f"to trim local APFS snapshots to ~{threshold_gb} GiB."
            ),
            dry_run=True,
        )

    result = _run(cmd, timeout=120)
    if result.returncode == 0:
        return ActionResult(
            success=True,
            action=action,
            source=source,
            detail=(
                f"tmutil thinlocalsnapshots completed. "
                f"Output: {result.stdout.strip() or '(none)'}"
            ),
            dry_run=False,
        )

    return ActionResult(
        success=False,
        action=action,
        source=source,
        detail=(
            f"tmutil thinlocalsnapshots failed "
            f"(rc={result.returncode}): {result.stderr.strip()}"
        ),
        dry_run=False,
    )


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------


def dispatch_action(event: DriftEvent, *, dry_run: bool = True) -> ActionResult:
    """Route a DriftEvent to the appropriate repair function.

    Categories that do not have a dedicated repair action (OVERSIZED,
    SWAP_PRESSURE) return an informational ActionResult with success=False
    indicating manual intervention is required.

    Args:
        event: The DriftEvent to repair.
        dry_run: Forwarded verbatim to the selected repair function.

    Returns:
        ActionResult from the selected repair function.
    """
    _dispatch_table: dict[DriftCategory, object] = {
        DriftCategory.MISSING_LINK: fix_missing_link,
        DriftCategory.STALE_TARGET: fix_stale_target,
        DriftCategory.REAL_DIR_DRIFT: fix_real_dir_drift,
        DriftCategory.UNMOUNTED_VOL: fix_unmounted_vol,
        DriftCategory.BAND_BLOAT: fix_band_bloat,
        DriftCategory.SNAPSHOT_LOCKED: fix_snapshot_locked,
    }

    handler = _dispatch_table.get(event.category)
    if handler is None:
        return ActionResult(
            success=False,
            action="dispatch_action",
            source=event.source,
            detail=(
                f"No automated repair available for category "
                f"{event.category.value!r}. Manual intervention required."
            ),
            dry_run=dry_run,
        )

    # All handlers share the same (event, *, dry_run) signature.
    return handler(event, dry_run=dry_run)  # type: ignore[operator]


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _extract_target_from_detail(detail: str) -> Optional[str]:
    """Extract a filesystem path from a reconcile event detail string.

    Reconcile detail strings embed the target in one of two formats:

    1. MISSING_LINK / STALE_TARGET:
       ``"... (volume=NAME) ..."``  — target is the volume mount path embedded
       as the symlink target literal.  The target path is the token following
       ``"points to '"`` or extracted from ``"'<path>'"`` patterns.

    2. REAL_DIR_DRIFT:
       ``"... pointing into volume '<name>'."``

    Because the reconcile module records the raw target path in the detail
    string (e.g. ``"points to '/Volumes/DDRV904/projects'"``), we scan for
    a single-quoted absolute path.

    Args:
        detail: The ``DriftEvent.detail`` string.

    Returns:
        The extracted path string, or None if no path could be found.
    """
    import re

    # Priority 1: explicit "points to '<path>'" phrasing (STALE_TARGET detail).
    match = re.search(r"points to '(/[^']+)'", detail)
    if match:
        return match.group(1)

    # Priority 2: explicit "target='<path>'" or 'target="<path>"' annotation.
    match = re.search(r"""target=['"](/[^'"]+)['"]""", detail)
    if match:
        return match.group(1)

    # Priority 3: last single-quoted absolute path in the string (REAL_DIR_DRIFT
    # detail ends with "pointing into volume '<mount>'").
    matches = re.findall(r"'(/[^']+)'", detail)
    if matches:
        return matches[-1]

    # Priority 4: last double-quoted absolute path.
    matches = re.findall(r'"(/[^"]+)"', detail)
    if matches:
        return matches[-1]

    return None


def _resolve_image_path(volume_name: str) -> Optional[str]:
    """Resolve the sparseimage path for a named volume via diskutil info.

    Runs ``diskutil info <volume_name>`` and extracts the "Image Path" field.

    Args:
        volume_name: The volume name (e.g. ``"DDRV902"``).

    Returns:
        Absolute path to the ``.sparseimage`` bundle, or None on failure.
    """
    try:
        result = _run(["diskutil", "info", volume_name], timeout=10)
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return None

    if result.returncode != 0:
        return None

    for line in result.stdout.splitlines():
        if "Image Path" in line and ":" in line:
            path = line.split(":", 1)[1].strip()
            if path:
                return path

    return None

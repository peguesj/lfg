"""DevDrive v2 Claude Code integration — symlink health and forest registration (US-010).

Manages the Claude Code directory structure (~/.claude/projects and ~/.claude/tasks)
as tracked forest entries.  After v2 migration these paths should be symlinks
pointing to native APFS volume mount points; this module discovers, verifies,
and registers them so the reconcile loop can auto-repair drift.

All filesystem calls (os.path.islink, os.readlink, os.symlink, os.makedirs,
os.path.exists, os.path.isdir) are invoked by name so they can be patched
in unit tests without real filesystem side-effects.

Typical usage::

    from devdrive_v2.claude_integration import full_health_check

    report = full_health_check()
    print(report)
"""

from __future__ import annotations

import logging
import os
import shutil
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from devdrive_v2.state import ForestEntry, ForestEntryKind, StateManager

logger = logging.getLogger(__name__)

# Stable IDs used when registering forest entries — kept constant so the
# reconcile loop can find and update the same entries across runs.
_ENTRY_ID_PROJECTS = "claude-code-projects"
_ENTRY_ID_TASKS = "claude-code-tasks"

_DEFAULT_VERIFY_DIRS = ["test-verify/nested/dir"]


# ---------------------------------------------------------------------------
# ClaudeCodePaths
# ---------------------------------------------------------------------------


@dataclass
class ClaudeCodePaths:
    """Resolved paths for the Claude Code directory structure.

    Attributes:
        claude_dir: Root ~/.claude directory (or override).
        projects_dir: ~/.claude/projects — Claude stores project memory here.
        tasks_dir: ~/.claude/tasks — Claude stores task state here.
    """

    claude_dir: Path = field(default_factory=lambda: Path.home() / ".claude")
    projects_dir: Path = field(
        default_factory=lambda: Path.home() / ".claude" / "projects"
    )
    tasks_dir: Path = field(
        default_factory=lambda: Path.home() / ".claude" / "tasks"
    )


# ---------------------------------------------------------------------------
# discover_claude_dirs
# ---------------------------------------------------------------------------


def discover_claude_dirs(claude_dir: Optional[Path] = None) -> ClaudeCodePaths:
    """Find the Claude Code directory structure and return resolved paths.

    Args:
        claude_dir: Override the root Claude directory.  Defaults to
            ``~/.claude``.

    Returns:
        A :class:`ClaudeCodePaths` instance with all three paths resolved
        relative to *claude_dir*.
    """
    root = claude_dir or (Path.home() / ".claude")
    return ClaudeCodePaths(
        claude_dir=root,
        projects_dir=root / "projects",
        tasks_dir=root / "tasks",
    )


# ---------------------------------------------------------------------------
# check_symlink_health
# ---------------------------------------------------------------------------


def check_symlink_health(paths: ClaudeCodePaths) -> list[dict[str, Any]]:
    """Return a health-check dict for each tracked Claude Code directory.

    For each of ``projects_dir`` and ``tasks_dir``:

    * Determines whether the path is a symlink (``os.path.islink``).
    * If a symlink, reads its target (``os.readlink``).
    * Checks whether the (resolved) target exists (``os.path.exists``).
    * Probes write access by attempting ``os.makedirs`` on a transient
      subdirectory inside the resolved path, then removing it.

    The write-access probe uses the resolved target when the path is a
    symlink; it falls back to the raw path otherwise.

    Args:
        paths: Claude Code directory structure as returned by
            :func:`discover_claude_dirs`.

    Returns:
        A list of dicts, one per directory, with the following keys:

        ``path`` (str)
            Absolute path being checked.

        ``is_symlink`` (bool)
            True when the path is a symlink.

        ``target`` (str | None)
            Symlink target if ``is_symlink`` is True, else None.

        ``target_exists`` (bool)
            True when the path (or its symlink target) exists on disk.

        ``writable`` (bool)
            True when a mkdir -p probe inside the directory succeeded.
    """
    results: list[dict[str, Any]] = []

    for dir_path in (paths.projects_dir, paths.tasks_dir):
        path_str = str(dir_path)
        is_symlink = os.path.islink(path_str)
        target: Optional[str] = None
        target_exists = False
        writable = False

        if is_symlink:
            try:
                target = os.readlink(path_str)
            except OSError as exc:
                logger.warning("os.readlink(%r) failed: %s", path_str, exc)
                target = None

            # A symlink target exists when the *destination* path is present.
            target_exists = os.path.exists(path_str)
        else:
            # Not a symlink — check whether the real path exists.
            target_exists = os.path.exists(path_str)

        # Write-access probe: try mkdir -p inside the directory.
        probe_base = target if (is_symlink and target is not None) else path_str
        probe_path = os.path.join(probe_base, "__lfg_write_probe__")
        try:
            os.makedirs(probe_path, exist_ok=True)
            # Clean up the probe directory.
            os.rmdir(probe_path)
            writable = True
        except OSError:
            writable = False

        results.append(
            {
                "path": path_str,
                "is_symlink": is_symlink,
                "target": target,
                "target_exists": target_exists,
                "writable": writable,
            }
        )

    return results


# ---------------------------------------------------------------------------
# register_forest_entries
# ---------------------------------------------------------------------------


def register_forest_entries(
    paths: ClaudeCodePaths,
    volume_name: str,
    state_mgr: StateManager,
) -> list[ForestEntry]:
    """Create and register ForestEntry objects for the Claude Code directories.

    Each entry is created with ``expected_kind=SYMLINK``, ``auto_repair=True``,
    and a target path of ``/Volumes/<volume_name>/<dir_name>``.  If an entry
    with the same ID already exists it is replaced.

    Args:
        paths: Claude Code paths as returned by :func:`discover_claude_dirs`.
        volume_name: Name of the APFS volume that should host the data
            (e.g. ``"DDRV-904-MEMVT"``).
        state_mgr: Loaded (or lazily-loading) :class:`StateManager` instance.
            The state is saved to disk before returning.

    Returns:
        The two :class:`ForestEntry` objects that were registered, in order
        (projects then tasks).
    """
    entries: list[ForestEntry] = []

    spec = [
        (_ENTRY_ID_PROJECTS, paths.projects_dir),
        (_ENTRY_ID_TASKS, paths.tasks_dir),
    ]

    for entry_id, dir_path in spec:
        dir_name = dir_path.name  # "projects" or "tasks"
        target = f"/Volumes/{volume_name}/{dir_name}"

        entry = ForestEntry(
            id=entry_id,
            system_path=str(dir_path),
            volume=volume_name,
            target=target,
            expected_kind=ForestEntryKind.SYMLINK.value,
            last_observed_kind=ForestEntryKind.MISSING.value,
            drift_count=0,
            auto_repair=True,
        )
        state_mgr.add_forest_entry(entry)
        entries.append(entry)
        logger.info(
            "Registered forest entry %r: %r -> %r (auto_repair=True)",
            entry_id,
            str(dir_path),
            target,
        )

    state_mgr.save()
    return entries


# ---------------------------------------------------------------------------
# verify_mkdir_p
# ---------------------------------------------------------------------------


def verify_mkdir_p(
    base_dir: Path,
    test_dirs: Optional[list[str]] = None,
) -> dict[str, Any]:
    """Test that ``mkdir -p`` works for a list of subdirectory paths.

    Each path in *test_dirs* is created under *base_dir* and then removed.
    The function is careful to remove only the leaf directory it created,
    leaving any pre-existing parent directories intact.

    Args:
        base_dir: Root directory inside which probes are created.
        test_dirs: Relative subdirectory paths to test.  Defaults to
            ``["test-verify/nested/dir"]``.

    Returns:
        A dict with the following keys:

        ``success`` (bool)
            True when every probe directory was created and removed
            without error.

        ``tested`` (int)
            Number of paths attempted.

        ``failed`` (list[str])
            Relative paths that could not be created or cleaned up.

        ``errors`` (list[str])
            Human-readable error messages for each failure, in the same
            order as *failed*.
    """
    dirs_to_test = test_dirs if test_dirs is not None else list(_DEFAULT_VERIFY_DIRS)
    failed: list[str] = []
    errors: list[str] = []

    for rel in dirs_to_test:
        full_path = str(base_dir / rel)
        try:
            os.makedirs(full_path, exist_ok=True)
        except OSError as exc:
            failed.append(rel)
            errors.append(f"mkdir -p {full_path!r}: {exc}")
            continue

        # Remove what we created — walk up from the leaf until we reach base_dir.
        _cleanup_probe(base_dir, rel)

    return {
        "success": len(failed) == 0,
        "tested": len(dirs_to_test),
        "failed": failed,
        "errors": errors,
    }


def _cleanup_probe(base_dir: Path, rel: str) -> None:
    """Best-effort removal of directories created by :func:`verify_mkdir_p`.

    Removes directories from the leaf up to (but not including) *base_dir*.
    Silently ignores errors (e.g. the directory is not empty due to a race).

    Args:
        base_dir: Root directory that must not be removed.
        rel: Relative path that was created.
    """
    parts = Path(rel).parts  # e.g. ("test-verify", "nested", "dir")
    # Walk from deepest to shallowest, stopping before base_dir itself.
    for depth in range(len(parts), 0, -1):
        candidate = base_dir / Path(*parts[:depth])
        try:
            os.rmdir(str(candidate))
        except OSError:
            break  # Either not empty or already gone — stop ascending.


# ---------------------------------------------------------------------------
# migrate_symlinks
# ---------------------------------------------------------------------------


def migrate_symlinks(
    paths: ClaudeCodePaths,
    target_volume: str,
    volumes_root: str = "/Volumes",
) -> list[dict[str, Any]]:
    """Update the projects and tasks symlinks to point to an APFS volume.

    For each of ``projects_dir`` and ``tasks_dir``:

    * **Already correct**: The symlink already points to the expected target
      under *volumes_root*/*target_volume* — skip with status ``"skipped"``.
    * **Needs update**: The path is a symlink but points elsewhere — remove
      the old symlink and create a new one; status ``"updated"``.
    * **Real directory**: The path is a real (non-symlink) directory — emit
      a warning, leave it untouched; status ``"skipped_real_dir"``.
    * **Absent**: The path does not exist at all — create the symlink;
      status ``"created"``.

    Args:
        paths: Claude Code paths as returned by :func:`discover_claude_dirs`.
        target_volume: Name of the APFS volume, e.g. ``"DDRV-904-MEMVT"``.
        volumes_root: Mount-point parent, default ``"/Volumes"``.

    Returns:
        A list of dicts (one per directory) with keys:

        ``path`` (str)
            The symlink path that was (or would be) modified.

        ``target`` (str)
            The intended symlink target.

        ``status`` (str)
            One of ``"skipped"``, ``"updated"``, ``"created"``,
            ``"skipped_real_dir"``, or ``"error"``.

        ``detail`` (str)
            Human-readable explanation.
    """
    results: list[dict[str, Any]] = []

    for dir_path in (paths.projects_dir, paths.tasks_dir):
        path_str = str(dir_path)
        dir_name = dir_path.name
        expected_target = os.path.join(volumes_root, target_volume, dir_name)

        result: dict[str, Any] = {
            "path": path_str,
            "target": expected_target,
            "status": "error",
            "detail": "",
        }

        if os.path.islink(path_str):
            try:
                current_target = os.readlink(path_str)
            except OSError as exc:
                result["detail"] = f"os.readlink failed: {exc}"
                results.append(result)
                continue

            if current_target == expected_target:
                result["status"] = "skipped"
                result["detail"] = (
                    f"Already points to correct target {expected_target!r}."
                )
                results.append(result)
                continue

            # Symlink exists but points elsewhere — update it.
            try:
                os.unlink(path_str)
                os.symlink(expected_target, path_str)
                result["status"] = "updated"
                result["detail"] = (
                    f"Updated symlink from {current_target!r} to "
                    f"{expected_target!r}."
                )
            except OSError as exc:
                result["status"] = "error"
                result["detail"] = f"Failed to update symlink: {exc}"
            results.append(result)
            continue

        if os.path.isdir(path_str):
            # Real directory — do not touch it.
            logger.warning(
                "%r is a real directory, not a symlink. Skipping migration.",
                path_str,
            )
            result["status"] = "skipped_real_dir"
            result["detail"] = (
                f"{path_str!r} is a real directory. "
                "Move or rsync its contents manually before migrating."
            )
            results.append(result)
            continue

        # Path does not exist — create the symlink.
        try:
            parent = os.path.dirname(path_str)
            if parent:
                os.makedirs(parent, exist_ok=True)
            os.symlink(expected_target, path_str)
            result["status"] = "created"
            result["detail"] = (
                f"Created new symlink {path_str!r} -> {expected_target!r}."
            )
        except OSError as exc:
            result["status"] = "error"
            result["detail"] = f"Failed to create symlink: {exc}"
        results.append(result)

    return results


# ---------------------------------------------------------------------------
# full_health_check
# ---------------------------------------------------------------------------


def full_health_check(
    claude_dir: Optional[Path] = None,
    state_mgr: Optional[StateManager] = None,
) -> dict[str, Any]:
    """Orchestrate discovery, symlink health checks, and mkdir-p probes.

    Runs the following steps in sequence:

    1. :func:`discover_claude_dirs` to locate all Claude Code directories.
    2. :func:`check_symlink_health` on the discovered paths.
    3. :func:`verify_mkdir_p` on each directory that is both present and
       reachable (``target_exists`` is True in the health-check result).
    4. If *state_mgr* is provided, query it for existing forest entries
       for the Claude Code paths and include their registration status.

    Args:
        claude_dir: Optional override for the Claude root directory.
        state_mgr: Optional :class:`StateManager` instance.  When provided,
            the report includes ``registered`` (bool) and ``forest_entries``
            (list of serialised entry dicts) for the two known entry IDs.

    Returns:
        A comprehensive report dict with the following top-level keys:

        ``claude_dir`` (str)
            Resolved Claude root directory.

        ``projects_dir`` (str)
            Resolved projects directory.

        ``tasks_dir`` (str)
            Resolved tasks directory.

        ``symlink_health`` (list[dict])
            Output of :func:`check_symlink_health`.

        ``mkdir_probes`` (list[dict])
            One entry per directory (matching *symlink_health* order) with
            the output of :func:`verify_mkdir_p` merged with a ``path`` key.

        ``forest_registration`` (dict | None)
            Keys ``"projects"`` and ``"tasks"``, each with ``registered``
            (bool) and ``entry`` (dict | None).  Present only when
            *state_mgr* is supplied; otherwise this key is None.

        ``overall_healthy`` (bool)
            True when all symlinks point to existing targets and all
            mkdir-p probes succeeded.
    """
    paths = discover_claude_dirs(claude_dir)
    symlink_health = check_symlink_health(paths)

    mkdir_probes: list[dict[str, Any]] = []
    for health in symlink_health:
        dir_path = Path(health["path"])
        if health["target_exists"]:
            probe_result = verify_mkdir_p(dir_path)
        else:
            probe_result = {
                "success": False,
                "tested": 0,
                "failed": [],
                "errors": ["Directory not reachable; skipped mkdir probe."],
            }
        mkdir_probes.append({"path": health["path"], **probe_result})

    # Forest registration status.
    forest_registration: Optional[dict[str, Any]] = None
    if state_mgr is not None:
        projects_entry = state_mgr.find_forest_entry(_ENTRY_ID_PROJECTS)
        tasks_entry = state_mgr.find_forest_entry(_ENTRY_ID_TASKS)
        forest_registration = {
            "projects": {
                "registered": projects_entry is not None,
                "entry": projects_entry.to_dict() if projects_entry else None,
            },
            "tasks": {
                "registered": tasks_entry is not None,
                "entry": tasks_entry.to_dict() if tasks_entry else None,
            },
        }

    overall_healthy = all(
        h["target_exists"] for h in symlink_health
    ) and all(
        p["success"] for p in mkdir_probes
    )

    return {
        "claude_dir": str(paths.claude_dir),
        "projects_dir": str(paths.projects_dir),
        "tasks_dir": str(paths.tasks_dir),
        "symlink_health": symlink_health,
        "mkdir_probes": mkdir_probes,
        "forest_registration": forest_registration,
        "overall_healthy": overall_healthy,
    }

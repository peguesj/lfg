"""DevDrive v2 LaunchAgent lifecycle management (US-006).

Handles install, uninstall, start, stop, and verification of the
io.lfg.devdrive-reconcile LaunchAgent.  Also provides a migration helper
that removes the legacy io.lfg.devdrive-automount agent once the reconcile
loop has run successfully.

All subprocess calls go through the module-level ``_run`` wrapper so tests
can patch a single target.
"""

from __future__ import annotations

import logging
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

AGENT_LABEL = "io.lfg.devdrive-reconcile"
PLIST_FILENAME = "io.lfg.devdrive-reconcile.plist"
LAUNCH_AGENTS_DIR: Path = Path.home() / "Library" / "LaunchAgents"
PLIST_SOURCE: Path = Path(__file__).parent / "resources" / PLIST_FILENAME
LEGACY_AUTOMOUNT_LABEL = "io.lfg.devdrive-automount"

_LEGACY_PLIST_FILENAME = f"{LEGACY_AUTOMOUNT_LABEL}.plist"


# ---------------------------------------------------------------------------
# AgentResult
# ---------------------------------------------------------------------------


@dataclass
class AgentResult:
    """Outcome of a LaunchAgent lifecycle operation.

    Attributes:
        success: True when the operation completed without error.
        action: One of ``"install"``, ``"uninstall"``, ``"start"``,
            ``"stop"``, or ``"verify"``.
        message: Human-readable description of what happened (or what went
            wrong on failure).
    """

    success: bool
    action: str
    message: str


# ---------------------------------------------------------------------------
# Internal subprocess wrapper
# ---------------------------------------------------------------------------


def _run(args: Sequence[str], timeout: int = 30) -> subprocess.CompletedProcess:  # type: ignore[type-arg]
    """Run *args* as a subprocess and return the CompletedProcess.

    Args:
        args: Command and arguments to execute.
        timeout: Maximum seconds to wait before raising
            ``subprocess.TimeoutExpired``.

    Returns:
        A ``subprocess.CompletedProcess`` with ``returncode``, ``stdout``,
        and ``stderr`` populated.

    Raises:
        subprocess.TimeoutExpired: When the process exceeds *timeout*.
        FileNotFoundError: When the executable is not found on ``PATH``.
    """
    return subprocess.run(
        list(args),
        capture_output=True,
        text=True,
        timeout=timeout,
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def install() -> AgentResult:
    """Copy the plist from resources/ to ~/Library/LaunchAgents/ and lint it.

    The destination directory is created if it does not already exist.
    After copying, ``plutil -lint`` is run against the installed file to
    confirm the XML is well-formed.

    Returns:
        AgentResult with action ``"install"``.
    """
    dest = LAUNCH_AGENTS_DIR / PLIST_FILENAME

    try:
        LAUNCH_AGENTS_DIR.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(PLIST_SOURCE), str(dest))
    except OSError as exc:
        msg = f"Failed to copy plist to {dest}: {exc}"
        logger.error(msg)
        return AgentResult(success=False, action="install", message=msg)

    # Validate the plist with plutil.
    try:
        result = _run(["plutil", "-lint", str(dest)])
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        msg = f"plutil not available or timed out: {exc}"
        logger.warning(msg)
        # The copy succeeded even if we cannot validate; treat as success
        # with a caveat so callers can act on the message if needed.
        return AgentResult(success=True, action="install", message=msg)

    if result.returncode != 0:
        msg = (
            f"Plist lint failed for {dest}: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
        logger.error(msg)
        return AgentResult(success=False, action="install", message=msg)

    msg = f"Installed and validated {dest}"
    logger.info(msg)
    return AgentResult(success=True, action="install", message=msg)


def uninstall() -> AgentResult:
    """Stop the agent (if loaded) and remove the plist from LaunchAgents/.

    Returns:
        AgentResult with action ``"uninstall"``.
    """
    dest = LAUNCH_AGENTS_DIR / PLIST_FILENAME

    # Best-effort stop before removal; ignore failures.
    if is_loaded():
        _stop_result = stop()
        if not _stop_result.success:
            logger.warning(
                "Stop before uninstall returned failure: %s", _stop_result.message
            )

    if not dest.exists():
        msg = f"Plist not found at {dest}; nothing to remove"
        logger.info(msg)
        return AgentResult(success=True, action="uninstall", message=msg)

    try:
        dest.unlink()
    except OSError as exc:
        msg = f"Failed to remove {dest}: {exc}"
        logger.error(msg)
        return AgentResult(success=False, action="uninstall", message=msg)

    msg = f"Removed {dest}"
    logger.info(msg)
    return AgentResult(success=True, action="uninstall", message=msg)


def start() -> AgentResult:
    """Bootstrap the agent into the GUI domain.

    Uses ``launchctl bootstrap gui/<uid> <plist_path>`` (macOS 10.10+).

    Returns:
        AgentResult with action ``"start"``.
    """
    plist_path = LAUNCH_AGENTS_DIR / PLIST_FILENAME
    uid = os.getuid()
    domain_target = f"gui/{uid}"

    try:
        result = _run(
            ["launchctl", "bootstrap", domain_target, str(plist_path)]
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        msg = f"launchctl bootstrap failed: {exc}"
        logger.error(msg)
        return AgentResult(success=False, action="start", message=msg)

    if result.returncode != 0:
        msg = (
            f"launchctl bootstrap returned {result.returncode}: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
        logger.error(msg)
        return AgentResult(success=False, action="start", message=msg)

    msg = f"Agent {AGENT_LABEL} bootstrapped into {domain_target}"
    logger.info(msg)
    return AgentResult(success=True, action="start", message=msg)


def stop() -> AgentResult:
    """Boot out the agent from the GUI domain.

    Uses ``launchctl bootout gui/<uid>/<label>`` (macOS 10.10+).

    Returns:
        AgentResult with action ``"stop"``.
    """
    uid = os.getuid()
    service_target = f"gui/{uid}/{AGENT_LABEL}"

    try:
        result = _run(["launchctl", "bootout", service_target])
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        msg = f"launchctl bootout failed: {exc}"
        logger.error(msg)
        return AgentResult(success=False, action="stop", message=msg)

    if result.returncode != 0:
        msg = (
            f"launchctl bootout returned {result.returncode}: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
        logger.error(msg)
        return AgentResult(success=False, action="stop", message=msg)

    msg = f"Agent {AGENT_LABEL} booted out from {service_target}"
    logger.info(msg)
    return AgentResult(success=True, action="stop", message=msg)


def is_loaded() -> bool:
    """Return True when the agent is currently loaded in the GUI domain.

    Queries ``launchctl print gui/<uid>/<label>`` and treats a zero exit
    code as "loaded".

    Returns:
        True if the agent is loaded, False otherwise.
    """
    uid = os.getuid()
    service_target = f"gui/{uid}/{AGENT_LABEL}"

    try:
        result = _run(["launchctl", "print", service_target])
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def verify_boot_mount(volumes: list[str]) -> AgentResult:
    """Check that each volume name appears in ``mount`` output.

    Reads the system ``mount`` command and scans for each name in *volumes*.
    Reports any that are absent.

    Args:
        volumes: List of volume/filesystem names to verify are mounted.

    Returns:
        AgentResult with action ``"verify"``.  ``success`` is True only
        when *every* listed volume is found in mount output.
    """
    try:
        result = _run(["mount"])
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        msg = f"mount command failed: {exc}"
        logger.error(msg)
        return AgentResult(success=False, action="verify", message=msg)

    mount_output = result.stdout

    missing: list[str] = [v for v in volumes if v not in mount_output]

    if missing:
        msg = f"Volumes not found in mount output: {', '.join(missing)}"
        logger.warning(msg)
        return AgentResult(success=False, action="verify", message=msg)

    msg = f"All volumes verified mounted: {', '.join(volumes)}" if volumes else "No volumes to verify"
    logger.info(msg)
    return AgentResult(success=True, action="verify", message=msg)


def remove_legacy_automount() -> AgentResult:
    """Remove the legacy io.lfg.devdrive-automount agent if it exists.

    Should only be called after the reconcile loop has run successfully at
    least once.  Attempts to stop the agent via ``launchctl bootout`` before
    removing the plist file.

    Returns:
        AgentResult with action ``"uninstall"``.
    """
    legacy_plist = LAUNCH_AGENTS_DIR / _LEGACY_PLIST_FILENAME

    if not legacy_plist.exists():
        msg = f"Legacy agent plist not found at {legacy_plist}; nothing to do"
        logger.info(msg)
        return AgentResult(success=True, action="uninstall", message=msg)

    # Attempt to stop the legacy agent; tolerate failures.
    uid = os.getuid()
    legacy_service_target = f"gui/{uid}/{LEGACY_AUTOMOUNT_LABEL}"
    try:
        result = _run(["launchctl", "bootout", legacy_service_target])
        if result.returncode != 0:
            logger.warning(
                "launchctl bootout for legacy agent returned %d: %s",
                result.returncode,
                result.stderr.strip() or result.stdout.strip(),
            )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        logger.warning("Could not stop legacy agent before removal: %s", exc)

    try:
        legacy_plist.unlink()
    except OSError as exc:
        msg = f"Failed to remove legacy plist {legacy_plist}: {exc}"
        logger.error(msg)
        return AgentResult(success=False, action="uninstall", message=msg)

    msg = f"Legacy agent {LEGACY_AUTOMOUNT_LABEL} removed from {legacy_plist}"
    logger.info(msg)
    return AgentResult(success=True, action="uninstall", message=msg)


def setup_reconcile() -> AgentResult:
    """Orchestrate a full install-and-start sequence.

    Steps (in order):
    1. ``install()`` — copy and lint the plist.
    2. ``start()`` — bootstrap the agent into the GUI domain.
    3. Verify that the plist passes ``plutil -lint`` (covered by install).

    Returns early with a failure AgentResult if any step fails.

    Returns:
        AgentResult with action ``"install"`` on install failure,
        ``"start"`` on start failure, or ``"verify"`` on plutil failure.
        On full success the action is ``"verify"``.
    """
    install_result = install()
    if not install_result.success:
        return install_result

    start_result = start()
    if not start_result.success:
        return start_result

    # Confirm the installed plist lints cleanly as the verification gate.
    dest = LAUNCH_AGENTS_DIR / PLIST_FILENAME
    try:
        result = _run(["plutil", "-lint", str(dest)])
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        msg = f"plutil verification unavailable: {exc}"
        logger.warning(msg)
        # Plist was validated during install; treat as success with caveat.
        return AgentResult(success=True, action="verify", message=msg)

    if result.returncode != 0:
        msg = (
            f"Post-install plist verification failed: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
        logger.error(msg)
        return AgentResult(success=False, action="verify", message=msg)

    msg = (
        f"setup_reconcile complete: agent {AGENT_LABEL} installed, "
        "started, and plist verified"
    )
    logger.info(msg)
    return AgentResult(success=True, action="verify", message=msg)

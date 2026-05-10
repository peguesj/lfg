#!/usr/bin/env python3
"""LFG DevDrive daemon — self-correcting reconcile loop.

Runs an infinite reconcile pass every INTERVAL_SECONDS (default 300).
On each tick the daemon classifies drift via ReconcileLoop.classify_drift()
and POSTs a summary notification to the CCEM APM bridge.

Runtime files
-------------
PID  : ~/.config/lfg/daemon.pid
Log  : ~/.config/lfg/daemon.log  (JSONL, one record per tick)

Signal handling
---------------
SIGTERM / SIGINT  -> graceful shutdown (removes PID file, flushes final log line)
SIGHUP            -> reload state file path from environment (zero-downtime config reload)

Usage
-----
    python3 devdrive/daemon.py [--interval SECONDS] [--state PATH] [--log PATH]
    python3 devdrive/daemon.py --once   # single reconcile pass then exit (useful for LaunchAgent)
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Ensure the devdrive package is importable regardless of cwd.
# ---------------------------------------------------------------------------

_HERE = Path(__file__).parent.resolve()
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from devdrive_v2.reconcile import ReconcileLoop  # noqa: E402
from devdrive_v2.state import StateManager        # noqa: E402

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_INTERVAL = 300                        # 5 minutes
DEFAULT_STATE_PATH = Path.home() / ".config" / "lfg" / "devdrive_state.json"
DEFAULT_LOG_PATH = Path.home() / ".config" / "lfg" / "daemon.log"
DEFAULT_PID_PATH = Path.home() / ".config" / "lfg" / "daemon.pid"
APM_NOTIFY_URL = "http://localhost:3032/api/notify"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------


def _configure_logging(log_path: Path) -> None:
    """Set up root logger to emit JSONL records to log_path and INFO to stderr."""
    log_path.parent.mkdir(parents=True, exist_ok=True)

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)

    # Human-readable stderr handler.
    stderr_handler = logging.StreamHandler(sys.stderr)
    stderr_handler.setLevel(logging.INFO)
    stderr_handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    )
    root.addHandler(stderr_handler)

    # JSONL file handler — one JSON object per log record.
    class _JsonlHandler(logging.FileHandler):
        def emit(self, record: logging.LogRecord) -> None:
            try:
                payload = {
                    "ts": record.created,
                    "level": record.levelname,
                    "logger": record.name,
                    "msg": record.getMessage(),
                }
                self.stream.write(json.dumps(payload) + "\n")
                self.stream.flush()
            except Exception:
                self.handleError(record)

    file_handler = _JsonlHandler(str(log_path), encoding="utf-8")
    file_handler.setLevel(logging.DEBUG)
    root.addHandler(file_handler)


logger = logging.getLogger("lfg.daemon")

# ---------------------------------------------------------------------------
# PID management
# ---------------------------------------------------------------------------


def _write_pid(pid_path: Path) -> None:
    pid_path.parent.mkdir(parents=True, exist_ok=True)
    pid_path.write_text(str(os.getpid()) + "\n", encoding="utf-8")
    logger.debug("PID %d written to %s", os.getpid(), pid_path)


def _remove_pid(pid_path: Path) -> None:
    try:
        pid_path.unlink(missing_ok=True)
    except OSError as exc:
        logger.warning("Could not remove PID file %s: %s", pid_path, exc)

# ---------------------------------------------------------------------------
# APM notification
# ---------------------------------------------------------------------------


def _apm_notify(title: str, message: str, event_count: int) -> None:
    """POST a summary notification to the CCEM APM bridge (best-effort)."""
    payload = json.dumps(
        {
            "project": "lfg",
            "type": "reconcile_tick",
            "title": title,
            "message": message,
            "meta": {"drift_events": event_count},
        }
    ).encode("utf-8")

    req = urllib.request.Request(
        APM_NOTIFY_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            logger.debug("APM notify response: %s", resp.status)
    except (urllib.error.URLError, OSError) as exc:
        logger.debug("APM notify skipped (daemon not reachable): %s", exc)

# ---------------------------------------------------------------------------
# Reconcile tick
# ---------------------------------------------------------------------------


def _run_tick(loop: ReconcileLoop) -> int:
    """Execute one reconcile pass. Returns the number of drift events found."""
    logger.info("Reconcile tick starting")
    start = time.monotonic()

    events = loop.classify_drift()

    elapsed = time.monotonic() - start
    logger.info(
        "Reconcile tick complete: %d drift event(s) in %.2fs", len(events), elapsed
    )

    title = "DevDrive reconcile"
    if events:
        categories = ", ".join({e.category.value for e in events})
        message = f"{len(events)} drift event(s) detected: {categories}"
    else:
        message = "All volumes and symlinks healthy."

    _apm_notify(title, message, len(events))
    return len(events)

# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------

_shutdown_requested = False
_reload_requested = False


def _handle_sigterm(signum: int, _frame: object) -> None:
    global _shutdown_requested
    logger.info("Received signal %d — requesting graceful shutdown", signum)
    _shutdown_requested = True


def _handle_sighup(signum: int, _frame: object) -> None:
    global _reload_requested
    logger.info("Received SIGHUP — scheduling state reload")
    _reload_requested = True


def _install_signal_handlers() -> None:
    signal.signal(signal.SIGTERM, _handle_sigterm)
    signal.signal(signal.SIGINT, _handle_sigterm)
    try:
        signal.signal(signal.SIGHUP, _handle_sighup)
    except (OSError, AttributeError):
        pass  # Windows / restricted environments

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------


def run_daemon(
    interval: int,
    state_path: Path,
    log_path: Path,
    pid_path: Path,
    once: bool = False,
) -> None:
    """Start the reconcile daemon loop.

    Args:
        interval: Seconds between reconcile passes.
        state_path: Path to devdrive_state.json.
        log_path: Path for JSONL daemon log.
        pid_path: Path for PID file.
        once: If True, run a single pass then exit (no sleep loop).
    """
    global _shutdown_requested, _reload_requested

    _configure_logging(log_path)
    _install_signal_handlers()
    _write_pid(pid_path)

    logger.info(
        "LFG DevDrive daemon starting — PID %d, interval %ds, state %s",
        os.getpid(),
        interval,
        state_path,
    )

    try:
        mgr = StateManager(path=state_path)
        loop = ReconcileLoop(state_mgr=mgr)

        if once:
            _run_tick(loop)
            return

        while not _shutdown_requested:
            if _reload_requested:
                logger.info("Reloading StateManager from %s", state_path)
                mgr = StateManager(path=state_path)
                loop = ReconcileLoop(state_mgr=mgr)
                _reload_requested = False

            _run_tick(loop)

            # Sleep in short chunks so signal handlers can interrupt promptly.
            deadline = time.monotonic() + interval
            while time.monotonic() < deadline and not _shutdown_requested:
                time.sleep(min(5.0, deadline - time.monotonic()))

    except Exception as exc:
        logger.exception("Daemon crashed: %s", exc)
        raise
    finally:
        logger.info("LFG DevDrive daemon shutting down")
        _remove_pid(pid_path)

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="LFG DevDrive daemon — self-correcting reconcile loop.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=DEFAULT_INTERVAL,
        metavar="SECONDS",
        help="Seconds between reconcile passes.",
    )
    parser.add_argument(
        "--state",
        type=Path,
        default=DEFAULT_STATE_PATH,
        metavar="PATH",
        help="Path to devdrive_state.json.",
    )
    parser.add_argument(
        "--log",
        type=Path,
        default=DEFAULT_LOG_PATH,
        metavar="PATH",
        help="Path for JSONL daemon log.",
    )
    parser.add_argument(
        "--pid",
        type=Path,
        default=DEFAULT_PID_PATH,
        metavar="PATH",
        help="Path for PID file.",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run a single reconcile pass then exit (no sleep loop).",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> None:
    args = _build_parser().parse_args(argv)
    run_daemon(
        interval=args.interval,
        state_path=args.state,
        log_path=args.log,
        pid_path=args.pid,
        once=args.once,
    )


if __name__ == "__main__":
    main()

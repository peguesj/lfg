"""apm_outbox — Append-only APM event outbox writer.

Queues lifecycle transition payloads to ``~/.config/lfg/apm-outbox.jsonl``
when the Phoenix ``BackendLifecycleStore`` endpoint is unreachable per
ADR-002 §Negative consequences.

The outbox is a plain JSONL file: one JSON object per line, append-only.
A future replay process (Phoenix task or bash helper) can drain it once APM
recovers.  This module only **writes** — it never reads, replays, or
truncates the file.

Each line written contains:
    - ``enqueued_at``: ISO-8601 UTC timestamp of the enqueue call.
    - ``event_type``: Namespaced event string (e.g. ``"devdrive.lifecycle.transition"``).
    - ``backend_id``: The fleet backend identifier.
    - ``payload``: The original POST body dict that was not delivered.

File-level safety:
    The outbox directory is created with ``mkdir -p`` semantics on first
    write.  Individual line writes use a single ``file.write()`` call
    (which is atomic for lines short enough to fit in the OS pipe buffer,
    typically 4 KB on Darwin) to avoid interleaved partial lines from
    concurrent writers.

Typical usage::

    from devdrive.apm_outbox import enqueue

    enqueue(
        event_type="devdrive.lifecycle.transition",
        backend_id="901DEVLIB",
        payload={"from": "healthy", "to": "degraded", "evidence": {}},
    )
"""

from __future__ import annotations

import datetime
import json
import logging
import os
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# Default outbox location per ADR-002 §Negative.
DEFAULT_OUTBOX_PATH: Path = (
    Path.home() / ".config" / "lfg" / "apm-outbox.jsonl"
)


def enqueue(
    event_type: str,
    backend_id: str,
    payload: dict[str, Any],
    *,
    outbox_path: Path = DEFAULT_OUTBOX_PATH,
) -> None:
    """Append one outbox record to the JSONL file.

    Creates the parent directory if it does not exist.  Silently logs and
    returns on any ``OSError`` so callers are never blocked by a write
    failure (the outbox is best-effort).

    Args:
        event_type: Namespaced event string, e.g.
            ``"devdrive.lifecycle.transition"``.
        backend_id: The fleet.json ``drives[].id`` value.
        payload: The full POST body dict that was not delivered to Phoenix.
        outbox_path: Override the default outbox file path (used in tests).
    """
    record: dict[str, Any] = {
        "enqueued_at": _utc_now_iso(),
        "event_type": event_type,
        "backend_id": backend_id,
        "payload": payload,
    }
    line = json.dumps(record, separators=(",", ":")) + "\n"

    try:
        outbox_path.parent.mkdir(parents=True, exist_ok=True)
        # Open in append mode; on Darwin a single write() of a line that
        # fits inside the OS pipe buffer is effectively atomic.
        with open(outbox_path, "a", encoding="utf-8") as fh:
            fh.write(line)
        logger.debug(
            "apm_outbox: enqueued %s for %s to %s",
            event_type,
            backend_id,
            outbox_path,
        )
    except OSError as exc:
        # Never raise — the outbox is best-effort.
        logger.warning(
            "apm_outbox: failed to write to %s: %s", outbox_path, exc
        )


def _utc_now_iso() -> str:
    """Return the current UTC time as an ISO-8601 string with Z suffix.

    Returns:
        e.g. ``"2026-06-16T05:30:00.123456Z"``
    """
    return (
        datetime.datetime.now(tz=datetime.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z")
    )


def pending_count(*, outbox_path: Path = DEFAULT_OUTBOX_PATH) -> int:
    """Return the number of undelivered records in the outbox file.

    Counts non-empty lines; does not parse JSON.  Useful for health checks
    and test assertions.

    Args:
        outbox_path: Override the default outbox file path.

    Returns:
        Number of non-empty lines in the file, or 0 if the file does not exist.
    """
    if not outbox_path.exists():
        return 0
    try:
        with open(outbox_path, "r", encoding="utf-8") as fh:
            return sum(1 for line in fh if line.strip())
    except OSError as exc:
        logger.warning(
            "apm_outbox: could not read %s for count: %s", outbox_path, exc
        )
        return 0

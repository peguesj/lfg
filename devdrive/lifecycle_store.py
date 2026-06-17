"""lifecycle_store — Python client for the Phoenix BackendLifecycleStore.

Posts state-machine transitions to ``POST /api/devdrive/{backend_id}/state``
per ADR-002. Falls back to the APM outbox (``apm_outbox``) when the Phoenix
endpoint is unreachable so the daemon never blocks on a downed APM server.

Seven canonical lifecycle states (LFG-98 §2.2, RUNTIME_HARDENING §2):

    healthy → degraded → fallback_active → backend_rebuilt
            → sync_in_progress → sync_verifying → reclaimed → healthy

The valid transition map is mirrored here for defensive pre-flight checks;
the Phoenix GenServer is the authoritative enforcer and will return 409 on
invalid edges.

Typical usage::

    from devdrive.lifecycle_store import transition, LifecycleState

    ok, err = transition(
        backend_id="901DEVLIB",
        from_state=LifecycleState.HEALTHY,
        to_state=LifecycleState.DEGRADED,
        evidence={"detail": "mount_point absent"},
        metadata={"producer_pipeline": "python.reconcile"},
    )
    if not ok:
        print(f"Transition failed: {err}")
"""

from __future__ import annotations

import http.client
import json
import logging
import re
import socket
from enum import Enum
from typing import Any, Optional

from devdrive.apm_outbox import enqueue as _outbox_enqueue

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Host and port are module-level constants, not interpolated into URLs.
# The path segment is the only variable; it is validated before use.
_APM_HOST: str = "localhost"
_APM_PORT: int = 3032
_POST_TIMEOUT_S: int = 5  # aggressive — never block the reconcile loop


# ---------------------------------------------------------------------------
# LifecycleState
# ---------------------------------------------------------------------------


class LifecycleState(str, Enum):
    """Canonical backend lifecycle state atoms (LFG-98 §2.2).

    Values match the Elixir atom names serialised as strings over the wire.
    """

    HEALTHY = "healthy"
    DEGRADED = "degraded"
    FALLBACK_ACTIVE = "fallback_active"
    BACKEND_REBUILT = "backend_rebuilt"
    SYNC_IN_PROGRESS = "sync_in_progress"
    SYNC_VERIFYING = "sync_verifying"
    RECLAIMED = "reclaimed"


# ---------------------------------------------------------------------------
# Valid transition map — Python-side pre-flight (Phoenix is authoritative)
# ---------------------------------------------------------------------------

_VALID_TRANSITIONS: dict[LifecycleState, frozenset[LifecycleState]] = {
    LifecycleState.HEALTHY: frozenset(
        {LifecycleState.DEGRADED, LifecycleState.FALLBACK_ACTIVE}
    ),
    LifecycleState.DEGRADED: frozenset(
        {LifecycleState.HEALTHY, LifecycleState.FALLBACK_ACTIVE}
    ),
    LifecycleState.FALLBACK_ACTIVE: frozenset(
        {LifecycleState.BACKEND_REBUILT, LifecycleState.DEGRADED}
    ),
    LifecycleState.BACKEND_REBUILT: frozenset(
        {
            LifecycleState.SYNC_IN_PROGRESS,
            LifecycleState.DEGRADED,
            LifecycleState.FALLBACK_ACTIVE,
        }
    ),
    LifecycleState.SYNC_IN_PROGRESS: frozenset(
        {LifecycleState.SYNC_VERIFYING, LifecycleState.BACKEND_REBUILT}
    ),
    LifecycleState.SYNC_VERIFYING: frozenset(
        {LifecycleState.RECLAIMED, LifecycleState.BACKEND_REBUILT}
    ),
    LifecycleState.RECLAIMED: frozenset({LifecycleState.HEALTHY}),
}


def is_valid_transition(
    from_state: LifecycleState, to_state: LifecycleState
) -> bool:
    """Return True if the from→to edge is present in the valid transition map.

    This is a client-side pre-flight check only. The Phoenix GenServer
    (``BackendLifecycleStore.transition/3``) is the authoritative enforcer and
    will reject invalid edges with a 409.

    Args:
        from_state: The current lifecycle state of the backend.
        to_state: The proposed next state.

    Returns:
        True when the transition is listed in ``_VALID_TRANSITIONS``.
    """
    return to_state in _VALID_TRANSITIONS.get(from_state, frozenset())


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def transition(
    backend_id: str,
    from_state: LifecycleState,
    to_state: LifecycleState,
    evidence: dict[str, Any],
    metadata: Optional[dict[str, Any]] = None,
) -> tuple[bool, Optional[str]]:
    """Post a lifecycle transition to the Phoenix BackendLifecycleStore.

    If the HTTP POST succeeds (2xx response) the transition is recorded by
    Phoenix, written to the JSONL append-only log, and broadcast over PubSub.

    When the Phoenix endpoint is unreachable (``ConnectionRefusedError``,
    timeout, or any ``OSError``), the transition payload is appended to the
    APM outbox at ``~/.config/lfg/apm-outbox.jsonl`` so it can be replayed
    once APM recovers (ADR-002 §Negative consequences).

    Args:
        backend_id: The fleet.json ``drives[].id`` value, e.g. ``"901DEVLIB"``.
        from_state: The current lifecycle state asserted by the caller.
        to_state: The desired next lifecycle state.
        evidence: Arbitrary dict of observation data; for corruption events
            this should be a ``CorruptionSignature.to_dict()`` result.
        metadata: Optional producer metadata (e.g.
            ``{"producer_pipeline": "python.reconcile"}``).

    Returns:
        A 2-tuple ``(success: bool, error_message: Optional[str])``.
        ``(True, None)`` on a successful POST.
        ``(False, "<reason>")`` when the POST failed — the payload was
        enqueued to the outbox before returning.
    """
    if not is_valid_transition(from_state, to_state):
        msg = (
            f"Invalid transition {from_state.value!r} → {to_state.value!r} "
            f"for backend {backend_id!r}; skipping POST."
        )
        logger.warning(msg)
        return False, msg

    payload: dict[str, Any] = {
        "from": from_state.value,
        "to": to_state.value,
        "evidence": evidence,
        "producer_pipeline": (metadata or {}).get(
            "producer_pipeline", "python.lifecycle_store"
        ),
    }
    if metadata:
        payload["metadata"] = metadata

    # Validate backend_id before embedding in the path. Accept only the
    # fleet.json id format (alphanumeric + hyphen/underscore, 1–64 chars).
    # This prevents path-traversal via a crafted backend_id value.
    if not re.fullmatch(r"[A-Za-z0-9_\-]{1,64}", backend_id):
        msg = (
            f"backend_id {backend_id!r} contains invalid characters; "
            "refusing to POST."
        )
        logger.error(msg)
        return False, msg

    # Use http.client.HTTPConnection with the module-level host + port
    # constants. This stdlib class has no scheme-dispatch layer and cannot
    # load file:// or any non-HTTP URI, eliminating CWE-939 entirely.
    # The path component is the only dynamic segment; it is validated above.
    path = "/api/devdrive/" + backend_id + "/state"
    body = json.dumps(payload).encode("utf-8")
    err: str = ""

    try:
        conn = http.client.HTTPConnection(
            _APM_HOST, _APM_PORT, timeout=_POST_TIMEOUT_S
        )
        conn.request(
            "POST",
            path,
            body=body,
            headers={"Content-Type": "application/json"},
        )
        resp = conn.getresponse()
        status = resp.status
        resp.read()  # drain body so the connection can be reused/closed
        conn.close()

        if 200 <= status < 300:
            logger.info(
                "lifecycle transition %s → %s for %s: HTTP %d",
                from_state.value,
                to_state.value,
                backend_id,
                status,
            )
            return True, None

        # Non-2xx — log and fall through to outbox.
        err = f"POST {path} returned HTTP {status}"
        logger.warning("%s; enqueuing to outbox", err)

    except (http.client.HTTPException, OSError, socket.timeout) as exc:
        err = f"POST {path} unreachable: {exc}"
        logger.warning("%s; enqueuing to outbox", err)

    # Outbox fallback (ADR-002 §Negative).
    _outbox_enqueue(
        event_type="devdrive.lifecycle.transition",
        backend_id=backend_id,
        payload=payload,
    )
    return False, err

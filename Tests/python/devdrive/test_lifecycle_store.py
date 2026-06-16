"""lifecycle_store unit tests (LFG-107).

Run with:
    PYTHONPATH=devdrive pytest tests/python/devdrive/test_lifecycle_store.py -v

Tests the Python-side lifecycle_store module: is_valid_transition, backend_id
validation, transition() HTTP client behaviour, and outbox fallback.
All network and filesystem I/O is monkeypatched.
"""

from __future__ import annotations

import http.client
import json
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

from devdrive.lifecycle_store import (
    LifecycleState,
    _VALID_TRANSITIONS,
    is_valid_transition,
    transition,
)


# ---------------------------------------------------------------------------
# is_valid_transition — client-side pre-flight graph invariants
# ---------------------------------------------------------------------------


class TestIsValidTransition:
    """Client-side pre-flight transition graph invariants."""

    def test_healthy_to_degraded_valid_when_called_returnsTrue(self) -> None:
        """healthy → degraded is a valid edge in the pre-flight map."""
        assert is_valid_transition(LifecycleState.HEALTHY, LifecycleState.DEGRADED) is True

    def test_healthy_to_reclaimed_invalid_when_called_returnsFalse(self) -> None:
        """healthy → reclaimed is NOT a valid edge."""
        assert is_valid_transition(LifecycleState.HEALTHY, LifecycleState.RECLAIMED) is False

    def test_full_happy_path_chain_when_eachEdgeChecked_allReturnTrue(self) -> None:
        """Every edge in the full reclaim chain must be valid:
        healthy→degraded→fallback_active→backend_rebuilt→sync_in_progress→sync_verifying→reclaimed→healthy.
        """
        chain = [
            (LifecycleState.HEALTHY, LifecycleState.DEGRADED),
            (LifecycleState.DEGRADED, LifecycleState.FALLBACK_ACTIVE),
            (LifecycleState.FALLBACK_ACTIVE, LifecycleState.BACKEND_REBUILT),
            (LifecycleState.BACKEND_REBUILT, LifecycleState.SYNC_IN_PROGRESS),
            (LifecycleState.SYNC_IN_PROGRESS, LifecycleState.SYNC_VERIFYING),
            (LifecycleState.SYNC_VERIFYING, LifecycleState.RECLAIMED),
            (LifecycleState.RECLAIMED, LifecycleState.HEALTHY),
        ]
        for from_s, to_s in chain:
            assert is_valid_transition(from_s, to_s) is True, (
                f"{from_s.value} → {to_s.value} must be a valid transition edge"
            )

    def test_valid_transitions_map_contains_14_edges_total(self) -> None:
        """The _VALID_TRANSITIONS map must contain exactly 14 valid edges total
        (per LFG-98 §2.3 and phoenix-backendlifecyclestore.md §10 full matrix).
        """
        total_edges = sum(len(v) for v in _VALID_TRANSITIONS.values())
        assert total_edges == 14, (
            f"Expected 14 total valid edges but found {total_edges}. "
            "Update _VALID_TRANSITIONS if the state machine changed."
        )


# ---------------------------------------------------------------------------
# transition() — HTTP POST behaviour and outbox fallback
# ---------------------------------------------------------------------------


def _make_mock_response(status: int) -> MagicMock:
    """Build a minimal mock HTTPResponse with the given status code."""
    mock_resp = MagicMock()
    mock_resp.status = status
    mock_resp.read.return_value = b""
    return mock_resp


class TestTransition:
    """HTTP POST behaviour and outbox fallback for lifecycle_store.transition()."""

    def test_invalid_backend_id_rejected_when_pathTraversalChars_returnsFalseWithoutPosting(
        self,
    ) -> None:
        """backend_id with path-traversal characters returns (False, error) without any HTTP call."""
        with patch("http.client.HTTPConnection") as mock_conn_cls:
            ok, err = transition(
                backend_id="../../etc/passwd",
                from_state=LifecycleState.HEALTHY,
                to_state=LifecycleState.DEGRADED,
                evidence={},
            )

        assert ok is False, "Path-traversal backend_id must return False"
        assert err is not None and "invalid characters" in err.lower(), (
            "Error message must mention invalid characters"
        )
        mock_conn_cls.assert_not_called()  # Must abort before any HTTP call.

    def test_invalid_transition_returns_false_when_invalidEdge_returnsFalseBeforeNetworkCall(
        self,
    ) -> None:
        """An invalid from→to pair returns (False, msg) before any network call."""
        with patch("http.client.HTTPConnection") as mock_conn_cls:
            ok, err = transition(
                backend_id="901DEVLIB",
                from_state=LifecycleState.HEALTHY,
                to_state=LifecycleState.RECLAIMED,  # not a valid edge from HEALTHY
                evidence={},
            )

        assert ok is False, "Invalid transition must return (False, ...)"
        assert err is not None and "invalid" in err.lower(), (
            "Error message must describe the invalid transition"
        )
        mock_conn_cls.assert_not_called()  # Must abort before any HTTP call.

    def test_successful_post_returns_true_when_mock200Response_returnsTrueNone(
        self,
    ) -> None:
        """A mocked 2xx response returns (True, None) without touching the outbox."""
        mock_resp = _make_mock_response(200)

        with patch("http.client.HTTPConnection") as mock_conn_cls, \
             patch("devdrive.lifecycle_store._outbox_enqueue") as mock_enqueue:
            mock_instance = mock_conn_cls.return_value
            mock_instance.getresponse.return_value = mock_resp

            ok, err = transition(
                backend_id="901DEVLIB",
                from_state=LifecycleState.HEALTHY,
                to_state=LifecycleState.DEGRADED,
                evidence={"detail": "mount_point absent"},
            )

        assert ok is True, "HTTP 200 response must return (True, None)"
        assert err is None, "No error message on success"
        mock_enqueue.assert_not_called()  # Outbox must NOT be touched on success.

    def test_connection_refused_enqueues_outbox_when_connectionRefused_returnsFalseAndEnqueues(
        self,
    ) -> None:
        """When http.client raises ConnectionRefusedError the payload lands in the outbox."""
        with patch("http.client.HTTPConnection") as mock_conn_cls, \
             patch("devdrive.lifecycle_store._outbox_enqueue") as mock_enqueue:
            mock_instance = mock_conn_cls.return_value
            mock_instance.request.side_effect = ConnectionRefusedError("Connection refused")

            ok, err = transition(
                backend_id="901DEVLIB",
                from_state=LifecycleState.HEALTHY,
                to_state=LifecycleState.DEGRADED,
                evidence={},
            )

        assert ok is False, "ConnectionRefusedError must return (False, ...)"
        assert err is not None and "unreachable" in err.lower(), (
            "Error message must indicate the endpoint was unreachable"
        )
        mock_enqueue.assert_called_once()  # Outbox must be written exactly once.

        # Verify the outbox call received the expected event_type.
        call_kwargs = mock_enqueue.call_args
        assert call_kwargs.kwargs.get("event_type") == "devdrive.lifecycle.transition" or \
               (len(call_kwargs.args) > 0 and call_kwargs.args[0] == "devdrive.lifecycle.transition"), \
               "Outbox event_type must be 'devdrive.lifecycle.transition'"

    def test_non_2xx_enqueues_outbox_when_500Response_returnsFalseAndEnqueues(
        self,
    ) -> None:
        """A 500 response from Phoenix enqueues to the outbox and returns (False, msg)."""
        mock_resp = _make_mock_response(500)

        with patch("http.client.HTTPConnection") as mock_conn_cls, \
             patch("devdrive.lifecycle_store._outbox_enqueue") as mock_enqueue:
            mock_instance = mock_conn_cls.return_value
            mock_instance.getresponse.return_value = mock_resp

            ok, err = transition(
                backend_id="901DEVLIB",
                from_state=LifecycleState.HEALTHY,
                to_state=LifecycleState.DEGRADED,
                evidence={},
            )

        assert ok is False, "HTTP 500 response must return (False, ...)"
        assert "500" in (err or ""), "Error message must include the HTTP status code"
        mock_enqueue.assert_called_once()

    def test_uses_http_client_not_urllib_when_moduleInspected_usesHttpClientImport(
        self,
    ) -> None:
        """The lifecycle_store module must import http.client, not urllib.request."""
        import devdrive.lifecycle_store as lc_module

        # Verify http.client is accessible as a direct attribute of the module
        # (it was imported at module level, not just used via a string reference).
        assert hasattr(lc_module, "http"), (
            "lifecycle_store must have 'http' in its namespace (from `import http.client`)"
        )
        # Confirm urllib.request is not imported (should not be in module globals).
        assert "urllib" not in dir(lc_module), (
            "lifecycle_store must NOT import urllib; use http.client exclusively"
        )

    def test_transition_payload_includes_from_and_to_states_when_posted_bodyIsCorrect(
        self,
    ) -> None:
        """The POST body must include 'from' and 'to' state strings (Phoenix contract LFG-98 §4.4)."""
        mock_resp = _make_mock_response(200)
        captured_body: list[bytes] = []

        def capture_request(method: str, path: str, body: bytes, headers: Any) -> None:
            captured_body.append(body)

        with patch("http.client.HTTPConnection") as mock_conn_cls:
            mock_instance = mock_conn_cls.return_value
            mock_instance.request.side_effect = capture_request
            mock_instance.getresponse.return_value = mock_resp

            transition(
                backend_id="901DEVLIB",
                from_state=LifecycleState.HEALTHY,
                to_state=LifecycleState.DEGRADED,
                evidence={"detail": "mount absent"},
                metadata={"producer_pipeline": "python.test"},
            )

        assert len(captured_body) == 1, "Exactly one HTTP request body must be captured"
        body_dict = json.loads(captured_body[0])
        assert body_dict["from"] == "healthy", "POST body must contain 'from' key with state string"
        assert body_dict["to"] == "degraded", "POST body must contain 'to' key with state string"
        assert "evidence" in body_dict, "POST body must include 'evidence' dict"

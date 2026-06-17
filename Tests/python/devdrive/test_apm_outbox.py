"""apm_outbox unit tests (LFG-107).

Run with:
    PYTHONPATH=devdrive pytest tests/python/devdrive/test_apm_outbox.py -v

All tests use a tmp_path-scoped outbox file; no real ~/.config paths are touched.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from unittest.mock import patch

import pytest

from devdrive.apm_outbox import DEFAULT_OUTBOX_PATH, enqueue, pending_count


# ---------------------------------------------------------------------------
# TestEnqueue — append-only write behaviour
# ---------------------------------------------------------------------------


class TestEnqueue:
    """Append-only write behaviour of apm_outbox.enqueue()."""

    def test_creates_parent_directory_when_parentAbsent_directoryCreated(
        self, tmp_path: Path
    ) -> None:
        """enqueue() creates the outbox parent directory when it does not exist."""
        outbox = tmp_path / "deep" / "nested" / "outbox.jsonl"
        assert not outbox.parent.exists(), "Parent directory must not exist before enqueue"

        enqueue(
            event_type="devdrive.lifecycle.transition",
            backend_id="901DEVLIB",
            payload={"from": "healthy", "to": "degraded", "evidence": {}},
            outbox_path=outbox,
        )

        assert outbox.parent.exists(), "enqueue must create parent directories"
        assert outbox.exists(), "Outbox file must be created by the first enqueue call"

    def test_appends_valid_json_line_when_called_outputIsValidJson(
        self, tmp_path: Path
    ) -> None:
        """Each enqueue() call appends exactly one valid JSON line."""
        outbox = tmp_path / "outbox.jsonl"

        enqueue(
            event_type="devdrive.lifecycle.transition",
            backend_id="901DEVLIB",
            payload={"from": "healthy", "to": "degraded", "evidence": {}},
            outbox_path=outbox,
        )

        lines = outbox.read_text().splitlines()
        assert len(lines) == 1, "Exactly one line must be written by a single enqueue call"

        record = json.loads(lines[0])
        assert "enqueued_at" in record
        assert "event_type" in record
        assert "backend_id" in record
        assert "payload" in record

    def test_multiple_enqueues_accumulate_when_calledTwice_twoLinesNeverOverwriting(
        self, tmp_path: Path
    ) -> None:
        """Two enqueue() calls produce two lines, never overwriting the first."""
        outbox = tmp_path / "outbox.jsonl"

        enqueue(
            event_type="devdrive.lifecycle.transition",
            backend_id="901DEVLIB",
            payload={"from": "healthy", "to": "degraded", "evidence": {}},
            outbox_path=outbox,
        )
        enqueue(
            event_type="devdrive.lifecycle.transition",
            backend_id="901DEVLIB",
            payload={"from": "degraded", "to": "fallback_active", "evidence": {}},
            outbox_path=outbox,
        )

        lines = [l for l in outbox.read_text().splitlines() if l.strip()]
        assert len(lines) == 2, "Two enqueue calls must produce exactly two lines"

        # Both lines must be valid JSON with distinct payloads.
        r1 = json.loads(lines[0])
        r2 = json.loads(lines[1])
        assert r1["payload"]["from"] == "healthy"
        assert r2["payload"]["from"] == "degraded"

    def test_oserror_does_not_raise_when_writePathUnwritable_logsWarningAndReturns(
        self, tmp_path: Path, caplog: pytest.LogCaptureFixture
    ) -> None:
        """An OSError on the write path is swallowed (logged at WARNING)."""
        outbox = tmp_path / "outbox.jsonl"

        with caplog.at_level(logging.WARNING, logger="devdrive.apm_outbox"), \
             patch("builtins.open", side_effect=OSError("Permission denied")):
            # Must not raise even when open() fails.
            enqueue(
                event_type="devdrive.lifecycle.transition",
                backend_id="901DEVLIB",
                payload={"from": "healthy", "to": "degraded", "evidence": {}},
                outbox_path=outbox,
            )

        assert any("apm_outbox" in r.name and r.levelno == logging.WARNING
                   for r in caplog.records), \
            "OSError on write must produce a WARNING log from devdrive.apm_outbox"

    def test_record_contains_required_fields_when_enqueued_allFieldsPresent(
        self, tmp_path: Path
    ) -> None:
        """Each record must contain enqueued_at, event_type, backend_id, payload."""
        outbox = tmp_path / "outbox.jsonl"

        enqueue(
            event_type="devdrive.lifecycle.transition",
            backend_id="904MEMVT",
            payload={"from": "fallback_active", "to": "backend_rebuilt", "evidence": {}},
            outbox_path=outbox,
        )

        record = json.loads(outbox.read_text().strip())
        assert "enqueued_at" in record, "Record must have 'enqueued_at'"
        assert "event_type" in record, "Record must have 'event_type'"
        assert "backend_id" in record, "Record must have 'backend_id'"
        assert "payload" in record, "Record must have 'payload'"

        assert record["event_type"] == "devdrive.lifecycle.transition"
        assert record["backend_id"] == "904MEMVT"

    def test_enqueued_at_is_utc_iso8601_when_fieldParsed_endsWithZ(
        self, tmp_path: Path
    ) -> None:
        """enqueued_at must be a valid ISO-8601 string ending in 'Z' (UTC marker)."""
        outbox = tmp_path / "outbox.jsonl"

        enqueue(
            event_type="devdrive.lifecycle.transition",
            backend_id="901DEVLIB",
            payload={},
            outbox_path=outbox,
        )

        record = json.loads(outbox.read_text().strip())
        enqueued_at = record["enqueued_at"]

        assert isinstance(enqueued_at, str), "enqueued_at must be a string"
        assert enqueued_at.endswith("Z"), (
            f"enqueued_at must end with 'Z' (UTC marker), got: {enqueued_at!r}"
        )
        # Must parse as an ISO 8601 datetime without raising.
        from datetime import datetime, timezone
        # Remove Z and parse with fromisoformat (Python 3.11+) or replace for 3.9/3.10.
        parsed = datetime.fromisoformat(enqueued_at.replace("Z", "+00:00"))
        assert parsed.tzinfo is not None, "enqueued_at must be timezone-aware"


# ---------------------------------------------------------------------------
# TestPendingCount — pending_count() helper
# ---------------------------------------------------------------------------


class TestPendingCount:
    """pending_count() helper — line count without JSON parsing."""

    def test_returns_zero_when_file_absent_noOutboxFile_returnsZero(
        self, tmp_path: Path
    ) -> None:
        """pending_count() returns 0 when the outbox file does not exist."""
        non_existent = tmp_path / "missing.jsonl"
        assert not non_existent.exists()
        assert pending_count(outbox_path=non_existent) == 0

    def test_counts_non_empty_lines_when_threeEnqueues_returnsThree(
        self, tmp_path: Path
    ) -> None:
        """pending_count() matches the number of enqueue() calls."""
        outbox = tmp_path / "outbox.jsonl"

        for i in range(3):
            enqueue(
                event_type="devdrive.lifecycle.transition",
                backend_id=f"VOL{i}",
                payload={"seq": i},
                outbox_path=outbox,
            )

        count = pending_count(outbox_path=outbox)
        assert count == 3, f"Expected 3 pending records but got {count}"

    def test_counts_non_empty_lines_when_emptyLinesPresent_skipsEmptyLines(
        self, tmp_path: Path
    ) -> None:
        """pending_count() counts only non-empty lines (blank lines are ignored)."""
        outbox = tmp_path / "outbox.jsonl"
        # Write two real records and one blank line.
        outbox.write_text('{"event_type":"a"}\n\n{"event_type":"b"}\n')
        assert pending_count(outbox_path=outbox) == 2, \
            "Blank lines must not be counted as pending records"

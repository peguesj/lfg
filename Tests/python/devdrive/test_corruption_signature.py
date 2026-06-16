"""CorruptionSignature + ShadowOutcome unit tests (LFG-107).

Run with:
    PYTHONPATH=devdrive pytest tests/python/devdrive/test_corruption_signature.py -v

All tests are pure in-memory; no filesystem or subprocess calls.
"""

from __future__ import annotations

import pytest

from devdrive.corruption_signature import CorruptionSignature, ShadowOutcome


# ---------------------------------------------------------------------------
# ShadowOutcome factory + round-trip serialisation
# ---------------------------------------------------------------------------


class TestShadowOutcome:
    """ShadowOutcome factory classmethods + to_dict / from_dict round-trip."""

    def test_not_attempted_round_trip_when_serialisedAndDeserialsied_preservesKind(self) -> None:
        """not_attempted() serialises to {'kind': 'not_attempted'} and round-trips cleanly."""
        outcome = ShadowOutcome.not_attempted()
        assert outcome.kind == "not_attempted"
        assert outcome.fsck_clean is None
        assert outcome.reason is None

        as_dict = outcome.to_dict()
        assert as_dict == {"kind": "not_attempted"}

        reconstructed = ShadowOutcome.from_dict(as_dict)
        assert reconstructed == outcome

    def test_success_carries_fsck_clean_flag_when_trueAndRoundTripped_preservesFlag(self) -> None:
        """success(fsck_clean=True) carries the flag through to_dict / from_dict."""
        outcome = ShadowOutcome.success(fsck_clean=True)
        assert outcome.kind == "success"
        assert outcome.fsck_clean is True
        assert outcome.reason is None

        as_dict = outcome.to_dict()
        assert as_dict == {"kind": "success", "fsck_clean": True}

        reconstructed = ShadowOutcome.from_dict(as_dict)
        assert reconstructed.fsck_clean is True

    def test_success_carries_fsck_clean_flag_when_falseAndRoundTripped_preservesFlag(self) -> None:
        """success(fsck_clean=False) carries the False flag through serialisation."""
        outcome = ShadowOutcome.success(fsck_clean=False)
        as_dict = outcome.to_dict()
        reconstructed = ShadowOutcome.from_dict(as_dict)
        assert reconstructed.fsck_clean is False

    def test_failure_carries_reason_when_reasonStringProvided_preservesString(self) -> None:
        """failure(reason='Resource temporarily unavailable') preserves the reason string."""
        reason = "Resource temporarily unavailable"
        outcome = ShadowOutcome.failure(reason=reason)
        assert outcome.kind == "failure"
        assert outcome.reason == reason
        assert outcome.fsck_clean is None

        as_dict = outcome.to_dict()
        assert as_dict == {"kind": "failure", "reason": reason}

        reconstructed = ShadowOutcome.from_dict(as_dict)
        assert reconstructed.reason == reason

    def test_from_dict_rejects_unknown_kind_when_kindIsGarbage_raisesValueError(self) -> None:
        """from_dict raises ValueError for an unrecognised kind key."""
        with pytest.raises(ValueError, match="Unknown ShadowOutcome kind"):
            ShadowOutcome.from_dict({"kind": "totally_unknown"})

    def test_from_dict_rejects_empty_kind_when_kindMissing_raisesValueError(self) -> None:
        """from_dict raises ValueError when 'kind' key is absent (empty string fallback)."""
        with pytest.raises(ValueError, match="Unknown ShadowOutcome kind"):
            ShadowOutcome.from_dict({})

    def test_not_attempted_is_frozen_when_mutationAttempted_raisesAttributeError(self) -> None:
        """ShadowOutcome is a frozen dataclass — attribute assignment must raise."""
        outcome = ShadowOutcome.not_attempted()
        with pytest.raises((AttributeError, TypeError)):
            outcome.kind = "mutated"  # type: ignore[misc]


# ---------------------------------------------------------------------------
# CorruptionSignature value-type invariants
# ---------------------------------------------------------------------------


class TestCorruptionSignature:
    """CorruptionSignature immutability, wire format, and class-shape invariants."""

    def test_frozen_immutable_when_mutationAttempted_raisesAttributeError(self) -> None:
        """CorruptionSignature instances are immutable (frozen=True) — mutation raises."""
        sig = CorruptionSignature(
            hdiutil_errno=None,
            container_visible=True,
            shadow_attach_outcome=ShadowOutcome.not_attempted(),
        )
        with pytest.raises((AttributeError, TypeError)):
            sig.hdiutil_errno = 5  # type: ignore[misc]

    def test_to_dict_wire_format_when_classASignature_matchesPhoenixSchema(self) -> None:
        """to_dict() matches the Phoenix evidence schema for a Class A signature (LFG-98 §4.4)."""
        sig = CorruptionSignature(
            hdiutil_errno=None,
            container_visible=True,
            shadow_attach_outcome=ShadowOutcome.not_attempted(),
        )
        result = sig.to_dict()

        # Must have exactly these top-level keys.
        assert set(result.keys()) == {"hdiutil_errno", "container_visible", "shadow_attach_outcome"}
        assert result["hdiutil_errno"] is None
        assert result["container_visible"] is True
        assert result["shadow_attach_outcome"] == {"kind": "not_attempted"}

    def test_from_dict_round_trip_when_serialisedAndDeserialsied_producesEqualInstance(self) -> None:
        """from_dict(sig.to_dict()) produces an instance equal to the original."""
        sig = CorruptionSignature(
            hdiutil_errno=5,
            container_visible=False,
            shadow_attach_outcome=ShadowOutcome.success(fsck_clean=False),
        )
        reconstructed = CorruptionSignature.from_dict(sig.to_dict())
        assert reconstructed == sig

    def test_class_a_signature_shape_when_staleHalfAttach_hasExpectedValues(self) -> None:
        """Class A (stale half-attach): container_visible=True, errno=None, outcome=not_attempted.

        Per corruption-history-taxonomy.md §4 Class A detector signature row:
          hdiutil_attach_errno = EBUSY (or None for ghost-attach)
          container_visible    = False (no APFS container under device node)
          shadow_attach_outcome = not_attempted (pre-flight cut in)

        Note: the Python CorruptionSignature docstring example uses container_visible=True
        for the 'class A' example; the taxonomy table shows False for the EBUSY case.
        We test the nominal ghost-attach variant (errno=None, container_visible=True) which
        matches the docstring example shape.
        """
        sig = CorruptionSignature(
            hdiutil_errno=None,
            container_visible=True,
            shadow_attach_outcome=ShadowOutcome.not_attempted(),
        )
        assert sig.hdiutil_errno is None
        assert sig.container_visible is True
        assert sig.shadow_attach_outcome.kind == "not_attempted"

        # Wire format must include the shadow_attach_outcome sub-dict.
        wire = sig.to_dict()
        assert wire["shadow_attach_outcome"]["kind"] == "not_attempted"

    def test_class_b_signature_shape_when_superblockCorrupt_hasExpectedValues(self) -> None:
        """Class B (superblock corruption): errno=5, container_visible=False, outcome=success(False)."""
        sig = CorruptionSignature(
            hdiutil_errno=5,
            container_visible=False,
            shadow_attach_outcome=ShadowOutcome.success(fsck_clean=False),
        )
        assert sig.hdiutil_errno == 5
        assert sig.container_visible is False
        assert sig.shadow_attach_outcome.kind == "success"
        assert sig.shadow_attach_outcome.fsck_clean is False

        wire = sig.to_dict()
        assert wire["hdiutil_errno"] == 5
        assert wire["shadow_attach_outcome"]["fsck_clean"] is False

    def test_from_dict_when_errnoIsNull_parsesAsNone(self) -> None:
        """from_dict correctly handles JSON null for hdiutil_errno (Python None)."""
        data = {
            "hdiutil_errno": None,
            "container_visible": False,
            "shadow_attach_outcome": {"kind": "not_attempted"},
        }
        sig = CorruptionSignature.from_dict(data)
        assert sig.hdiutil_errno is None

    def test_from_dict_when_errnoIsInteger_parsesAsInt(self) -> None:
        """from_dict coerces numeric errno to int."""
        data = {
            "hdiutil_errno": 16,
            "container_visible": False,
            "shadow_attach_outcome": {"kind": "not_attempted"},
        }
        sig = CorruptionSignature.from_dict(data)
        assert sig.hdiutil_errno == 16
        assert isinstance(sig.hdiutil_errno, int)

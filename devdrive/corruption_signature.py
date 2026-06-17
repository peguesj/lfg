"""CorruptionSignature — Python mirror of the Swift CorruptionSignature struct.

Carries the 3-tuple ``(hdiutil_errno, container_visible, shadow_attach_outcome)``
that is the canonical classification input for all three language runtimes per
ADR-003. Matches the JSON wire format consumed by
``POST /api/devdrive/backends/{backend_id}/state`` (LFG-98 §4.4).

Field names use snake_case to match the Phoenix evidence schema.
``ShadowOutcome`` encodes identically to the Elixir/Swift counterparts per
ADR-003 §Decision paragraph 4.

    not_attempted  — primary attach succeeded, or Class A pre-flight fired
    success        — shadow attached; fsck_apfs -yn clean flag carried
    failure        — shadow attach failed

Typical usage::

    from devdrive.corruption_signature import CorruptionSignature, ShadowOutcome

    sig = CorruptionSignature(
        hdiutil_errno=5,
        container_visible=False,
        shadow_attach_outcome=ShadowOutcome.not_attempted(),
    )
    print(sig.to_dict())
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Optional


# ---------------------------------------------------------------------------
# ShadowOutcome — tri-state value type
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class ShadowOutcome:
    """Outcome of a readonly shadow-attach attempt.

    Construct via the three factory classmethods; do not call ``__init__``
    directly.

    Attributes:
        kind: One of ``"not_attempted"``, ``"success"``, ``"failure"``.
        fsck_clean: When ``kind="success"``, True if ``fsck_apfs -yn`` ran
            without errors. None otherwise.
        reason: When ``kind="failure"``, the error string from stderr. None
            otherwise.
    """

    kind: str
    fsck_clean: Optional[bool]
    reason: Optional[str]

    # -- Factories -----------------------------------------------------------

    @classmethod
    def not_attempted(cls) -> ShadowOutcome:
        """Primary attach succeeded, or Class A pre-flight short-circuited.

        Returns:
            A ShadowOutcome with kind ``"not_attempted"``.
        """
        return cls(kind="not_attempted", fsck_clean=None, reason=None)

    @classmethod
    def success(cls, *, fsck_clean: bool) -> ShadowOutcome:
        """Shadow attach succeeded; fsck result carried.

        Args:
            fsck_clean: True if ``fsck_apfs -yn`` found no errors on the
                shadow slice.

        Returns:
            A ShadowOutcome with kind ``"success"``.
        """
        return cls(kind="success", fsck_clean=fsck_clean, reason=None)

    @classmethod
    def failure(cls, *, reason: str) -> ShadowOutcome:
        """Shadow attach itself failed.

        Args:
            reason: stderr excerpt or short description of why the shadow
                attach failed.

        Returns:
            A ShadowOutcome with kind ``"failure"``.
        """
        return cls(kind="failure", fsck_clean=None, reason=reason)

    # -- Serialisation -------------------------------------------------------

    def to_dict(self) -> dict[str, Any]:
        """Return the Phoenix wire-format dict for this outcome.

        The schema matches ``evidence.shadow_attach_outcome`` in
        ``POST /api/devdrive/backends/{backend_id}/state`` (LFG-98 §4.4).

        Returns:
            A dict with a ``kind`` key and, conditionally, ``fsck_clean``
            or ``reason``.
        """
        result: dict[str, Any] = {"kind": self.kind}
        if self.kind == "success" and self.fsck_clean is not None:
            result["fsck_clean"] = self.fsck_clean
        if self.kind == "failure" and self.reason is not None:
            result["reason"] = self.reason
        return result

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> ShadowOutcome:
        """Reconstruct a ShadowOutcome from a wire-format dict.

        Args:
            data: Dict with at least a ``kind`` key.

        Returns:
            A ShadowOutcome instance.

        Raises:
            ValueError: When ``kind`` is not a recognised value.
        """
        kind = data.get("kind", "")
        if kind == "not_attempted":
            return cls.not_attempted()
        if kind == "success":
            return cls.success(fsck_clean=bool(data.get("fsck_clean", False)))
        if kind == "failure":
            return cls.failure(reason=str(data.get("reason", "")))
        raise ValueError(f"Unknown ShadowOutcome kind: {kind!r}")


# ---------------------------------------------------------------------------
# CorruptionSignature
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class CorruptionSignature:
    """3-tuple canonical classification input for DevDrive failure-class routing.

    Mirrors the Swift ``CorruptionSignature`` struct (LFG-99 §1) and the JSON
    evidence schema for ``POST /api/devdrive/backends/{backend_id}/state``
    (LFG-98 §4.4, ADR-003).

    All three language runtimes (Swift, Python, Phoenix) produce and consume
    this exact tuple; Phoenix stores it verbatim as ``LifecycleEvent.evidence``.

    Attributes:
        hdiutil_errno: The errno value from the ``hdiutil attach`` exit (e.g.
            ``5`` for ``EIO``/Resource busy). ``None`` when the attach
            produced no numeric errno (image not yet probed, or Class A
            pre-flight short-circuits before any attach attempt).
        container_visible: True when ``hdiutil info`` shows the image already
            attached to a device node. False when no device node is present.
        shadow_attach_outcome: Result of a readonly shadow-attach probe
            (``hdiutil attach -readonly -shadow … -nomount``). Use
            ``ShadowOutcome.not_attempted()`` when no shadow was needed.

    Examples:
        Class A (stale half-attach — autonomous reclaimable)::

            CorruptionSignature(
                hdiutil_errno=None,
                container_visible=True,
                shadow_attach_outcome=ShadowOutcome.not_attempted(),
            )

        Class B (superblock corruption — route to recovery agent)::

            CorruptionSignature(
                hdiutil_errno=5,
                container_visible=False,
                shadow_attach_outcome=ShadowOutcome.success(fsck_clean=False),
            )
    """

    hdiutil_errno: Optional[int]
    container_visible: bool
    shadow_attach_outcome: ShadowOutcome

    # -- Serialisation -------------------------------------------------------

    def to_dict(self) -> dict[str, Any]:
        """Serialise to the Phoenix evidence wire format (LFG-98 §4.4).

        Returns:
            A dict with keys ``hdiutil_errno``, ``container_visible``, and
            ``shadow_attach_outcome`` ready for embedding in a lifecycle
            transition POST body.
        """
        return {
            "hdiutil_errno": self.hdiutil_errno,
            "container_visible": self.container_visible,
            "shadow_attach_outcome": self.shadow_attach_outcome.to_dict(),
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CorruptionSignature:
        """Reconstruct a CorruptionSignature from a wire-format dict.

        Args:
            data: Dict with keys matching ``to_dict`` output.

        Returns:
            A CorruptionSignature instance.
        """
        errno_raw = data.get("hdiutil_errno")
        shadow_raw = data.get("shadow_attach_outcome", {"kind": "not_attempted"})
        return cls(
            hdiutil_errno=int(errno_raw) if errno_raw is not None else None,
            container_visible=bool(data.get("container_visible", False)),
            shadow_attach_outcome=ShadowOutcome.from_dict(shadow_raw),
        )

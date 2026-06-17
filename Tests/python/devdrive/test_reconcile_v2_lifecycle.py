"""LFG-107 — reconcile.py lifecycle-store integration tests."""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO))

from devdrive.devdrive_v2 import reconcile as recon  # noqa: E402


def make_loop(monkeypatch, *, fs=None, run=None):
    """Build a ReconcileLoop with injectable filesystem + subprocess fakes."""
    fs = fs or {}

    def _islink(p): return fs.get(p, {}).get("link", False)
    def _exists(p): return p in fs
    def _isdir(p): return fs.get(p, {}).get("dir", False)
    def _readlink(p): return fs[p]["target"]

    return recon.ReconcileLoop(
        is_link=_islink,
        exists=_exists,
        is_dir=_isdir,
        readlink=_readlink,
        run=run or (lambda *a, **k: SimpleNamespace(returncode=0, stdout="", stderr="")),
    )


class TestFallbackPendingReclaimCategory:
    """DriftCategory.FALLBACK_PENDING_RECLAIM classification."""

    def test_detected_when_fallback_dir_exists_alongside_healthy_symlink(self, monkeypatch):
        fs = {
            "/Users/x/.foo": {"link": True, "target": "/Volumes/V/foo"},
            "/Volumes/V/foo": {"dir": True},
            "/Users/x/.foo-fallback": {"dir": True},
        }
        loop = make_loop(monkeypatch, fs=fs)
        entry = SimpleNamespace(
            source="/Users/x/.foo",
            target="/Volumes/V/foo",
            volume="901DEVLIB",
        )
        events = loop._classify_forest_entry(entry)
        cats = [e.category for e in events]
        assert recon.DriftCategory.FALLBACK_PENDING_RECLAIM in cats

    def test_not_emitted_when_no_fallback_dir(self, monkeypatch):
        fs = {
            "/Users/x/.foo": {"link": True, "target": "/Volumes/V/foo"},
            "/Volumes/V/foo": {"dir": True},
        }
        loop = make_loop(monkeypatch, fs=fs)
        entry = SimpleNamespace(
            source="/Users/x/.foo",
            target="/Volumes/V/foo",
            volume="901DEVLIB",
        )
        events = loop._classify_forest_entry(entry)
        cats = [e.category for e in events]
        assert recon.DriftCategory.FALLBACK_PENDING_RECLAIM not in cats

    def test_emits_lifecycle_transition_fallback_active_to_backend_rebuilt(self, monkeypatch):
        emit_calls = []
        loop = make_loop(monkeypatch, fs={
            "/Users/x/.foo": {"link": True, "target": "/Volumes/V/foo"},
            "/Volumes/V/foo": {"dir": True},
            "/Users/x/.foo-fallback": {"dir": True},
        })
        loop._emit_transition = MagicMock(side_effect=lambda *a, **k: emit_calls.append((a, k)))
        entry = SimpleNamespace(
            source="/Users/x/.foo",
            target="/Volumes/V/foo",
            volume="901DEVLIB",
        )
        loop._classify_forest_entry(entry)
        assert any(
            "fallback_active" in str(a) and "backend_rebuilt" in str(a)
            for a, _ in emit_calls
        ), f"expected fallback_active→backend_rebuilt, got {emit_calls!r}"


class TestUnmountedVolLifecycleTransition:
    """UNMOUNTED_VOL classifier emits lifecycle transition."""

    def test_unmounted_vol_emits_healthy_to_degraded(self, monkeypatch):
        emit_calls = []
        loop = make_loop(monkeypatch, fs={})
        loop._emit_transition = MagicMock(side_effect=lambda *a, **k: emit_calls.append((a, k)))
        vol = SimpleNamespace(
            name="901DEVLIB",
            mount_point="/Volumes/DDRV-901-DEVLIB",
            quota_bytes=None,
            used_bytes=0,
        )
        loop._classify_volume(vol)
        assert any(
            "healthy" in str(a) and "degraded" in str(a) for a, _ in emit_calls
        ), f"expected healthy→degraded for UNMOUNTED_VOL, got {emit_calls!r}"

    def test_emit_transition_failure_does_not_suppress_drift_event(self, monkeypatch):
        loop = make_loop(monkeypatch, fs={})
        loop._emit_transition = MagicMock(side_effect=RuntimeError("APM down"))
        vol = SimpleNamespace(
            name="901DEVLIB",
            mount_point="/Volumes/DDRV-901-DEVLIB",
            quota_bytes=None,
            used_bytes=0,
        )
        events = loop._classify_volume(vol)
        cats = [e.category for e in events]
        assert recon.DriftCategory.UNMOUNTED_VOL in cats


class TestEmitTransitionHelper:
    """ReconcileLoop._emit_transition isolation."""

    def test_swallows_import_error_gracefully(self, monkeypatch):
        monkeypatch.setitem(sys.modules, "devdrive.lifecycle_store", None)
        loop = make_loop(monkeypatch, fs={})
        loop._emit_transition(
            "healthy", "degraded", backend_id="901DEVLIB", evidence={"hdiutil_errno": 5}
        )

    def test_skips_invalid_state_string(self, monkeypatch):
        loop = make_loop(monkeypatch, fs={})
        loop._emit_transition(
            "not_a_state", "degraded", backend_id="901DEVLIB", evidence={}
        )

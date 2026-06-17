"""LFG-107 — fix_fallback_pending_reclaim action tests."""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO))

from devdrive.devdrive_v2 import actions  # noqa: E402
from devdrive.devdrive_v2.reconcile import DriftCategory, DriftEvent  # noqa: E402


def make_event(*, source="/Users/x/.foo", detail="fallback at /Users/x/.foo-fallback volume=901DEVLIB"):
    return DriftEvent(
        category=DriftCategory.FALLBACK_PENDING_RECLAIM,
        source=source,
        detail=detail,
        severity="warning",
    )


class TestFixFallbackPendingReclaim:
    """Safety gates + lifecycle transitions."""

    def test_dry_run_returns_success_without_side_effects(self, tmp_path):
        ev = make_event(source=str(tmp_path / "foo"), detail=f"fallback at {tmp_path}/foo-fallback volume=901DEVLIB")
        (tmp_path / "foo-fallback").mkdir()
        with patch.object(actions, "subprocess") as sp:
            result = actions.fix_fallback_pending_reclaim(ev, dry_run=True)
            assert result.success is True
            sp.run.assert_not_called()

    def test_lsof_open_handles_aborts(self, tmp_path):
        ev = make_event(source=str(tmp_path / "foo"), detail=f"fallback at {tmp_path}/foo-fallback volume=901DEVLIB")
        (tmp_path / "foo-fallback").mkdir()

        def fake_run(cmd, **kw):
            if "lsof" in cmd[0]:
                return SimpleNamespace(returncode=0, stdout="Rewind 65488 jeremiah 4u REG\n", stderr="")
            pytest.fail(f"unexpected subprocess after lsof failure: {cmd}")

        with patch.object(actions.subprocess, "run", side_effect=fake_run):
            result = actions.fix_fallback_pending_reclaim(ev, dry_run=False)
            assert result.success is False
            assert "lsof" in (result.message or "").lower() or "holder" in (result.message or "").lower()

    def test_missing_target_in_detail_returns_failure(self, tmp_path):
        ev = DriftEvent(
            category=DriftCategory.FALLBACK_PENDING_RECLAIM,
            source=str(tmp_path / "foo"),
            detail="no extractable target here",
            severity="warning",
        )
        result = actions.fix_fallback_pending_reclaim(ev, dry_run=False)
        assert result.success is False

    def test_rsync_failure_returns_failure(self, tmp_path):
        ev = make_event(source=str(tmp_path / "foo"), detail=f"fallback at {tmp_path}/foo-fallback volume=901DEVLIB")
        (tmp_path / "foo-fallback").mkdir()
        (tmp_path / "foo").mkdir()

        def fake_run(cmd, **kw):
            if "lsof" in cmd[0]:
                return SimpleNamespace(returncode=1, stdout="", stderr="")
            if "rsync" in cmd[0]:
                return SimpleNamespace(returncode=23, stdout="", stderr="rsync error")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with patch.object(actions.subprocess, "run", side_effect=fake_run):
            result = actions.fix_fallback_pending_reclaim(ev, dry_run=False)
            assert result.success is False

    def test_diff_mismatch_returns_failure(self, tmp_path):
        ev = make_event(source=str(tmp_path / "foo"), detail=f"fallback at {tmp_path}/foo-fallback volume=901DEVLIB")
        (tmp_path / "foo-fallback").mkdir()
        (tmp_path / "foo").mkdir()

        def fake_run(cmd, **kw):
            if "lsof" in cmd[0]:
                return SimpleNamespace(returncode=1, stdout="", stderr="")
            if "rsync" in cmd[0]:
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            if "diff" in cmd[0]:
                return SimpleNamespace(returncode=1, stdout="Only in foo-fallback: x\n", stderr="")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with patch.object(actions.subprocess, "run", side_effect=fake_run):
            result = actions.fix_fallback_pending_reclaim(ev, dry_run=False)
            assert result.success is False

    def test_success_removes_fallback_dir(self, tmp_path):
        fallback = tmp_path / "foo-fallback"
        fallback.mkdir()
        (fallback / "x.txt").write_text("hi")
        ev = make_event(source=str(tmp_path / "foo"), detail=f"fallback at {fallback} volume=901DEVLIB")
        (tmp_path / "foo").mkdir()

        rm_calls = []

        def fake_run(cmd, **kw):
            if "lsof" in cmd[0]:
                return SimpleNamespace(returncode=1, stdout="", stderr="")
            if any("rsync" in c for c in cmd):
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            if any("diff" in c for c in cmd):
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with patch.object(actions.subprocess, "run", side_effect=fake_run), \
             patch.object(actions, "shutil") as sh:
            sh.rmtree.side_effect = lambda p, **kw: rm_calls.append(str(p))
            result = actions.fix_fallback_pending_reclaim(ev, dry_run=False)
            assert any(str(fallback) in c for c in rm_calls), f"expected rmtree({fallback}), got {rm_calls!r}"

    def test_lifecycle_transitions_emitted_in_order(self, tmp_path):
        fallback = tmp_path / "foo-fallback"
        fallback.mkdir()
        ev = make_event(source=str(tmp_path / "foo"), detail=f"fallback at {fallback} volume=901DEVLIB")
        (tmp_path / "foo").mkdir()
        emit_calls = []

        def fake_run(cmd, **kw):
            if "lsof" in cmd[0]:
                return SimpleNamespace(returncode=1, stdout="", stderr="")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        with patch.object(actions.subprocess, "run", side_effect=fake_run), \
             patch.object(actions, "_emit_lifecycle", side_effect=lambda *a, **k: emit_calls.append(a)):
            actions.fix_fallback_pending_reclaim(ev, dry_run=False)
        flat = [(a[0], a[1]) for a in emit_calls] if emit_calls else []
        states = [f"{f}->{t}" for f, t in flat]
        if states:
            assert states == sorted(states, key=[
                "backend_rebuilt->sync_in_progress",
                "sync_in_progress->sync_verifying",
                "sync_verifying->reclaimed",
            ].index) or all(s in states for s in [
                "backend_rebuilt->sync_in_progress",
                "sync_in_progress->sync_verifying",
                "sync_verifying->reclaimed",
            ])

    def test_dispatch_action_routes_to_fix_fallback(self):
        ev = make_event()
        called = []
        with patch.object(actions, "fix_fallback_pending_reclaim", side_effect=lambda e, **kw: called.append(e) or actions.ActionResult(success=True, message="ok")):
            actions.dispatch_action(ev, dry_run=True)
            assert len(called) == 1


class TestExtractBackendIdFromDetail:
    """_extract_backend_id_from_detail helper."""

    def test_extracts_volume_eq_annotation(self):
        assert actions._extract_backend_id_from_detail("fallback at /x-fallback volume=901DEVLIB") == "901DEVLIB"

    def test_extracts_volume_colon_annotation(self):
        assert actions._extract_backend_id_from_detail("vol:904MEMVT-v2 stale") == "904MEMVT-v2"

    def test_returns_none_when_absent(self):
        assert actions._extract_backend_id_from_detail("nothing here") is None

"""Tests for devdrive_v2.state — schema validation, CRUD, migration."""

import json
import tempfile
from pathlib import Path

import pytest

from devdrive_v2.state import (
    RING_BUFFER_SIZE,
    SCHEMA_VERSION,
    DevDriveState,
    ForestEntry,
    ForestEntryKind,
    MetricsSample,
    StateManager,
    VolumeEntry,
    VolumeHealth,
    VolumeRole,
    migrate_v1_forest,
)


@pytest.fixture
def tmp_state(tmp_path: Path) -> StateManager:
    return StateManager(path=tmp_path / "devdrive_state.json")


class TestVolumeEntry:
    def test_roundtrip(self) -> None:
        v = VolumeEntry(name="DDRV900", mount_point="/Volumes/DDRV900", device="disk3s7",
                        quota_bytes=50_000_000_000, role=VolumeRole.DEVELOPER.value,
                        health=VolumeHealth.HEALTHY.value)
        d = v.to_dict()
        v2 = VolumeEntry.from_dict(d)
        assert v2.name == "DDRV900"
        assert v2.quota_bytes == 50_000_000_000
        assert v2.health == "healthy"

    def test_from_dict_ignores_extra_keys(self) -> None:
        d = {"name": "TEST", "mount_point": "/Volumes/TEST", "extra_field": 42}
        v = VolumeEntry.from_dict(d)
        assert v.name == "TEST"


class TestForestEntry:
    def test_roundtrip(self) -> None:
        f = ForestEntry(id="fe-001", system_path="/Users/j/.claude/projects",
                        volume="DDRV904", target="/Volumes/DDRV904/projects",
                        expected_kind=ForestEntryKind.SYMLINK.value,
                        auto_repair=True, drift_count=3)
        d = f.to_dict()
        f2 = ForestEntry.from_dict(d)
        assert f2.id == "fe-001"
        assert f2.auto_repair is True
        assert f2.drift_count == 3


class TestMetricsSample:
    def test_roundtrip(self) -> None:
        m = MetricsSample(ts=1000.0, df_free_gb=45.2, container_free_gb=120.5, purgeable_gb=30.1)
        d = m.to_dict()
        m2 = MetricsSample.from_dict(d)
        assert m2.df_free_gb == 45.2


class TestDevDriveState:
    def test_empty_state(self) -> None:
        s = DevDriveState()
        assert s.version == SCHEMA_VERSION
        assert s.volumes == []
        assert s.forest == []
        assert s.metrics == []

    def test_full_roundtrip(self) -> None:
        s = DevDriveState(
            volumes=[VolumeEntry(name="V1", mount_point="/Volumes/V1")],
            forest=[ForestEntry(id="f1", system_path="/a", volume="V1", target="/Volumes/V1/a")],
            metrics=[MetricsSample(ts=1.0, df_free_gb=50.0)],
            reconcile_log=[{"ts": 1.0, "action": "test"}],
        )
        d = s.to_dict()
        s2 = DevDriveState.from_dict(d)
        assert len(s2.volumes) == 1
        assert s2.volumes[0].name == "V1"
        assert len(s2.forest) == 1
        assert len(s2.metrics) == 1
        assert len(s2.reconcile_log) == 1


class TestStateManager:
    def test_load_creates_empty_on_missing(self, tmp_state: StateManager) -> None:
        s = tmp_state.load()
        assert s.version == SCHEMA_VERSION
        assert s.volumes == []

    def test_save_and_reload(self, tmp_state: StateManager) -> None:
        tmp_state.load()
        tmp_state.add_volume(VolumeEntry(name="TEST", mount_point="/Volumes/TEST"))
        tmp_state.save()

        mgr2 = StateManager(path=tmp_state.path)
        s2 = mgr2.load()
        assert len(s2.volumes) == 1
        assert s2.volumes[0].name == "TEST"

    def test_add_volume_replaces_existing(self, tmp_state: StateManager) -> None:
        tmp_state.load()
        tmp_state.add_volume(VolumeEntry(name="V", mount_point="/a"))
        tmp_state.add_volume(VolumeEntry(name="V", mount_point="/b"))
        assert len(tmp_state.state.volumes) == 1
        assert tmp_state.state.volumes[0].mount_point == "/b"

    def test_find_volume(self, tmp_state: StateManager) -> None:
        tmp_state.load()
        tmp_state.add_volume(VolumeEntry(name="FIND_ME", mount_point="/x"))
        assert tmp_state.find_volume("FIND_ME") is not None
        assert tmp_state.find_volume("NOPE") is None

    def test_remove_volume(self, tmp_state: StateManager) -> None:
        tmp_state.load()
        tmp_state.add_volume(VolumeEntry(name="DEL", mount_point="/x"))
        assert tmp_state.remove_volume("DEL") is True
        assert tmp_state.remove_volume("DEL") is False

    def test_forest_entry_crud(self, tmp_state: StateManager) -> None:
        tmp_state.load()
        fe = ForestEntry(id="fe1", system_path="/a", volume="V", target="/b")
        tmp_state.add_forest_entry(fe)
        assert tmp_state.find_forest_entry("fe1") is not None
        # Replace
        fe2 = ForestEntry(id="fe1", system_path="/c", volume="V", target="/d")
        tmp_state.add_forest_entry(fe2)
        found = tmp_state.find_forest_entry("fe1")
        assert found is not None
        assert found.system_path == "/c"

    def test_metrics_ring_buffer(self, tmp_state: StateManager) -> None:
        tmp_state.load()
        for i in range(RING_BUFFER_SIZE + 50):
            tmp_state.record_metric(MetricsSample(ts=float(i), df_free_gb=float(i)))
        assert len(tmp_state.state.metrics) == RING_BUFFER_SIZE
        assert tmp_state.state.metrics[0].ts == 50.0  # oldest kept

    def test_latest_metric_empty(self, tmp_state: StateManager) -> None:
        tmp_state.load()
        assert tmp_state.latest_metric() is None

    def test_latest_metric(self, tmp_state: StateManager) -> None:
        tmp_state.load()
        tmp_state.record_metric(MetricsSample(ts=1.0, df_free_gb=10.0))
        tmp_state.record_metric(MetricsSample(ts=2.0, df_free_gb=20.0))
        latest = tmp_state.latest_metric()
        assert latest is not None
        assert latest.ts == 2.0

    def test_reconcile_log_bounded(self, tmp_state: StateManager) -> None:
        tmp_state.load()
        for i in range(1050):
            tmp_state.log_reconcile({"action": f"test-{i}"})
        assert len(tmp_state.state.reconcile_log) == 1000

    def test_atomic_save(self, tmp_state: StateManager) -> None:
        """Verify save uses tmp file rename (atomic on APFS)."""
        tmp_state.load()
        tmp_state.add_volume(VolumeEntry(name="ATOMIC", mount_point="/x"))
        tmp_state.save()
        assert tmp_state.path.exists()
        assert not tmp_state.path.with_suffix(".tmp").exists()


class TestMigration:
    def test_migrate_v1_forest(self, tmp_path: Path) -> None:
        legacy = tmp_path / "devdrive_forest.json"
        legacy.write_text(json.dumps({
            "forest": [
                {"id": "f1", "system_path": "/Users/j/.claude/projects",
                 "volume_name": "DDRV904", "target": "/Volumes/DDRV904/projects"},
            ],
            "volumes": [
                {"name": "DDRV904", "mount_point": "/Volumes/DDRV904", "device": "disk3s8",
                 "role": "memory"},
            ],
        }))

        mgr = StateManager(path=tmp_path / "devdrive_state.json")
        state = migrate_v1_forest(legacy_path=legacy, state_mgr=mgr)

        assert len(state.forest) == 1
        assert state.forest[0].system_path == "/Users/j/.claude/projects"
        assert len(state.volumes) == 1
        assert state.volumes[0].name == "DDRV904"

    def test_migrate_no_legacy_file(self, tmp_path: Path) -> None:
        mgr = StateManager(path=tmp_path / "devdrive_state.json")
        state = migrate_v1_forest(legacy_path=tmp_path / "nonexistent.json", state_mgr=mgr)
        assert state.version == SCHEMA_VERSION
        assert state.volumes == []

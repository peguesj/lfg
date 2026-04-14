"""DevDrive v2 state file — single source of truth for volume inventory,
forest topology, pressure metrics ring buffer, and reconcile history.

Schema version: 2.0.0
Default path: ~/.config/lfg/devdrive_state.json
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import asdict, dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Optional

SCHEMA_VERSION = "2.0.0"
RING_BUFFER_SIZE = 288  # 24h at 5-min resolution
DEFAULT_STATE_PATH = Path.home() / ".config" / "lfg" / "devdrive_state.json"
LEGACY_FOREST_PATH = Path.home() / ".config" / "lfg" / "devdrive_forest.json"


class VolumeRole(str, Enum):
    DEVELOPER = "developer"
    HOOKS = "hooks"
    MEMORY = "memory"
    LIBRARY = "library"
    ENVIRONMENT = "environment"
    GENERAL = "general"


class VolumeHealth(str, Enum):
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    CORRUPT = "corrupt"
    UNMOUNTED = "unmounted"
    UNKNOWN = "unknown"


class ForestEntryKind(str, Enum):
    SYMLINK = "symlink"
    DIRECTORY = "directory"
    MISSING = "missing"


@dataclass
class VolumeEntry:
    name: str
    mount_point: str
    device: str = ""
    quota_bytes: int = 0
    used_bytes: int = 0
    role: str = VolumeRole.GENERAL.value
    health: str = VolumeHealth.UNKNOWN.value
    last_reconcile: float = 0.0
    migrated_from: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> VolumeEntry:
        return cls(**{k: v for k, v in d.items() if k in cls.__dataclass_fields__})


@dataclass
class ForestEntry:
    id: str
    system_path: str
    volume: str
    target: str
    expected_kind: str = ForestEntryKind.SYMLINK.value
    last_observed_kind: str = ForestEntryKind.MISSING.value
    drift_count: int = 0
    auto_repair: bool = False

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> ForestEntry:
        return cls(**{k: v for k, v in d.items() if k in cls.__dataclass_fields__})


@dataclass
class MetricsSample:
    ts: float
    df_free_gb: float = 0.0
    container_free_gb: float = 0.0
    purgeable_gb: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> MetricsSample:
        return cls(**{k: v for k, v in d.items() if k in cls.__dataclass_fields__})


@dataclass
class DevDriveState:
    version: str = SCHEMA_VERSION
    volumes: list[VolumeEntry] = field(default_factory=list)
    forest: list[ForestEntry] = field(default_factory=list)
    metrics: list[MetricsSample] = field(default_factory=list)
    reconcile_log: list[dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "volumes": [v.to_dict() for v in self.volumes],
            "forest": [f.to_dict() for f in self.forest],
            "metrics": [m.to_dict() for m in self.metrics],
            "reconcile_log": self.reconcile_log,
        }

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> DevDriveState:
        return cls(
            version=d.get("version", SCHEMA_VERSION),
            volumes=[VolumeEntry.from_dict(v) for v in d.get("volumes", [])],
            forest=[ForestEntry.from_dict(f) for f in d.get("forest", [])],
            metrics=[MetricsSample.from_dict(m) for m in d.get("metrics", [])],
            reconcile_log=d.get("reconcile_log", []),
        )


class StateManager:
    """Read/write interface for devdrive_state.json.  All modules go through this."""

    def __init__(self, path: Optional[Path] = None) -> None:
        self.path = path or DEFAULT_STATE_PATH
        self._state: Optional[DevDriveState] = None

    def load(self) -> DevDriveState:
        if self.path.exists():
            with open(self.path) as f:
                data = json.load(f)
            self._state = DevDriveState.from_dict(data)
        else:
            self._state = DevDriveState()
        return self._state

    def save(self) -> None:
        if self._state is None:
            self._state = DevDriveState()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        with open(tmp, "w") as f:
            json.dump(self._state.to_dict(), f, indent=2)
            f.write("\n")
        tmp.rename(self.path)

    @property
    def state(self) -> DevDriveState:
        if self._state is None:
            self.load()
        assert self._state is not None
        return self._state

    # --- Volume API ---

    def add_volume(self, vol: VolumeEntry) -> None:
        existing = self.find_volume(vol.name)
        if existing is not None:
            self.state.volumes.remove(existing)
        self.state.volumes.append(vol)

    def find_volume(self, name: str) -> Optional[VolumeEntry]:
        for v in self.state.volumes:
            if v.name == name:
                return v
        return None

    def remove_volume(self, name: str) -> bool:
        vol = self.find_volume(name)
        if vol:
            self.state.volumes.remove(vol)
            return True
        return False

    # --- Forest API ---

    def add_forest_entry(self, entry: ForestEntry) -> None:
        existing = self.find_forest_entry(entry.id)
        if existing is not None:
            self.state.forest.remove(existing)
        self.state.forest.append(entry)

    def find_forest_entry(self, entry_id: str) -> Optional[ForestEntry]:
        for f in self.state.forest:
            if f.id == entry_id:
                return f
        return None

    # --- Metrics ring buffer API ---

    def record_metric(self, sample: MetricsSample) -> None:
        self.state.metrics.append(sample)
        if len(self.state.metrics) > RING_BUFFER_SIZE:
            self.state.metrics = self.state.metrics[-RING_BUFFER_SIZE:]

    def latest_metric(self) -> Optional[MetricsSample]:
        return self.state.metrics[-1] if self.state.metrics else None

    # --- Reconcile log API ---

    def log_reconcile(self, entry: dict[str, Any]) -> None:
        entry.setdefault("ts", time.time())
        self.state.reconcile_log.append(entry)
        # Keep last 1000 entries
        if len(self.state.reconcile_log) > 1000:
            self.state.reconcile_log = self.state.reconcile_log[-1000:]


def migrate_v1_forest(
    legacy_path: Optional[Path] = None,
    state_mgr: Optional[StateManager] = None,
) -> DevDriveState:
    """Read existing devdrive_forest.json, convert to v2 format."""
    legacy = legacy_path or LEGACY_FOREST_PATH
    mgr = state_mgr or StateManager()
    mgr.load()

    if not legacy.exists():
        return mgr.state

    with open(legacy) as f:
        v1 = json.load(f)

    # v1 forest entries are typically {system_path, target, volume_name}
    for i, entry in enumerate(v1.get("entries", v1.get("forest", []))):
        fe = ForestEntry(
            id=entry.get("id", f"migrated-{i}"),
            system_path=entry.get("system_path", entry.get("path", "")),
            volume=entry.get("volume_name", entry.get("volume", "")),
            target=entry.get("target", ""),
            expected_kind=ForestEntryKind.SYMLINK.value,
            last_observed_kind=ForestEntryKind.MISSING.value if not entry.get("target") else ForestEntryKind.SYMLINK.value,
        )
        mgr.add_forest_entry(fe)

    # v1 volume entries
    for vol_data in v1.get("volumes", []):
        ve = VolumeEntry(
            name=vol_data.get("name", ""),
            mount_point=vol_data.get("mount_point", vol_data.get("path", "")),
            device=vol_data.get("device", ""),
            role=vol_data.get("role", VolumeRole.GENERAL.value),
            health=VolumeHealth.UNKNOWN.value,
        )
        mgr.add_volume(ve)

    mgr.save()
    return mgr.state

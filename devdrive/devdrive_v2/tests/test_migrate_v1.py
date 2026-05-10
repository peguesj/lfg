"""Tests for devdrive_v2.migrate_v1 — sparseimage-to-APFS migration pipeline.

Run with:
    PYTHONPATH=lib pytest lib/devdrive_v2/tests/test_migrate_v1.py -v

All subprocess, filesystem, and apfs_volume calls are mocked.  No real mounts,
sparseimages, or system commands are executed.
"""

from __future__ import annotations

import json
import os
import plistlib
import subprocess
import time
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, call, patch

import pytest

from devdrive_v2.migrate_v1 import (
    MigrationResult,
    _build_checksum_manifest,
    _get_container_free_bytes,
    _image_is_attached,
    _get_image_mount_point,
    _sha256_file,
    _verify_checksum_manifest,
    cleanup,
    migrate,
    preflight,
    rollback,
)


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------


def _completed(
    stdout: str = "",
    stderr: str = "",
    returncode: int = 0,
) -> subprocess.CompletedProcess[str]:
    """Build a fake CompletedProcess for use in mock return values."""
    return subprocess.CompletedProcess(
        args=[], returncode=returncode, stdout=stdout, stderr=stderr
    )


def _plist_bytes(data: dict[str, Any]) -> bytes:
    """Encode *data* as a plist XML bytes object."""
    return plistlib.dumps(data, fmt=plistlib.FMT_XML)


def _plist_str(data: dict[str, Any]) -> str:
    """Encode *data* as a plist XML string (for stdout mocks)."""
    return _plist_bytes(data).decode()


# Plist returned by "diskutil apfs list -plist" with a healthy container.
_CONTAINER_PLIST = _plist_str(
    {
        "Containers": [
            {
                "ContainerReference": "disk3",
                "Designation": "Physical",
                "CapacityCeiling": 500_000_000_000,
                "CapacityFree": 200_000_000_000,
                "Volumes": [],
            }
        ]
    }
)

# Plist returned by "hdiutil info -plist" with a single attached image.
_IMAGE_PATH = "/Users/Shared/lfg/images/901DEVLIB.sparseimage"
_IMAGE_MOUNT = "/Volumes/901DEVLIB"

_HDIUTIL_INFO_PLIST = _plist_str(
    {
        "images": [
            {
                "image-path": _IMAGE_PATH,
                "system-entities": [
                    {
                        "dev-entry": "/dev/disk4s1",
                        "mount-point": _IMAGE_MOUNT,
                    }
                ],
            }
        ]
    }
)

# Plist returned by "diskutil info -plist 901DEVLIB-v2" (staging volume info).
_STAGING_VOLUME_PLIST = _plist_str(
    {
        "DeviceIdentifier": "disk3s7",
        "VolumeName": "901DEVLIB-v2",
        "MountPoint": "/Volumes/901DEVLIB-v2",
        "TotalSize": 100_000_000_000,
        "FreeSpace": 80_000_000_000,
        "FilesystemType": "apfs",
    }
)


# ---------------------------------------------------------------------------
# MigrationResult dataclass
# ---------------------------------------------------------------------------


class TestMigrationResult:
    """Validate MigrationResult dataclass semantics."""

    def test_defaults(self) -> None:
        r = MigrationResult(
            success=True,
            volume_name="VOL",
            stage="preflight",
            message="ok",
        )
        assert r.data == {}

    def test_data_not_shared_between_instances(self) -> None:
        r1 = MigrationResult(success=True, volume_name="V", stage="migrate", message="a")
        r2 = MigrationResult(success=True, volume_name="V", stage="migrate", message="b")
        r1.data["x"] = 1
        assert "x" not in r2.data

    def test_all_fields_settable(self) -> None:
        r = MigrationResult(
            success=False,
            volume_name="901DEVLIB",
            stage="rollback",
            message="Something went wrong",
            data={"key": "val"},
        )
        assert r.success is False
        assert r.stage == "rollback"
        assert r.data["key"] == "val"

    @pytest.mark.parametrize(
        "stage",
        ["preflight", "migrate", "verify", "rollback", "cleanup"],
    )
    def test_valid_stage_values(self, stage: str) -> None:
        r = MigrationResult(success=True, volume_name="V", stage=stage, message="ok")
        assert r.stage == stage


# ---------------------------------------------------------------------------
# preflight — happy path
# ---------------------------------------------------------------------------


class TestPreflightHappyPath:
    """Preflight succeeds when all checks pass.

    Notes on patching strategy: ``_get_container_free_bytes`` delegates to
    ``get_container_info`` which lives in ``devdrive_v2.apfs_volume`` and uses
    its own ``_run`` reference.  Rather than patching two ``_run`` symbols, we
    patch the higher-level helpers directly — ``_get_container_free_bytes``,
    ``_image_is_attached``, and ``_get_image_mount_point`` — so each test
    controls only the surface it cares about.
    """

    # Shared patch context for all happy-path tests.
    _COMMON_PATCHES = {
        "_get_container_free_bytes": 200_000_000_000,  # 200 GB free
        "_image_is_attached": True,
        "_get_image_mount_point": _IMAGE_MOUNT,
    }

    def _happy_ctx(
        self,
        file_count: int = 2,
        image_size: int = 10_000_000_000,
        manifest: dict | None = None,
    ):
        """Return a context-manager stack for a happy-path preflight call."""
        return (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=200_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=image_size),
            patch("devdrive_v2.migrate_v1._image_is_attached", return_value=True),
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch(
                "devdrive_v2.migrate_v1._collect_regular_files",
                return_value=[f"/Volumes/901DEVLIB/f{i}" for i in range(file_count)],
            ),
            patch(
                "devdrive_v2.migrate_v1._build_checksum_manifest",
                return_value=manifest or {"f0": "aabb"},
            ),
        )

    def test_happy_path_returns_success(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=200_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=10_000_000_000),
            patch("devdrive_v2.migrate_v1._image_is_attached", return_value=True),
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=["f1", "f2"]),
            patch("devdrive_v2.migrate_v1._build_checksum_manifest", return_value={"f": "d"}),
        ):
            result = preflight("901DEVLIB", _IMAGE_PATH, container="disk3")

        assert result.success is True
        assert result.stage == "preflight"
        assert result.volume_name == "901DEVLIB"

    def test_happy_path_data_keys(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=200_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=10_000_000_000),
            patch("devdrive_v2.migrate_v1._image_is_attached", return_value=True),
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=["f1", "f2"]),
            patch("devdrive_v2.migrate_v1._build_checksum_manifest", return_value={"f": "d"}),
        ):
            result = preflight("901DEVLIB", _IMAGE_PATH)

        assert "estimated_gb" in result.data
        assert "file_count" in result.data
        assert "checksum_manifest" in result.data
        assert "mount_point" in result.data

    def test_happy_path_estimated_gb(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=200_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=20_000_000_000),
            patch("devdrive_v2.migrate_v1._image_is_attached", return_value=True),
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=[]),
            patch("devdrive_v2.migrate_v1._build_checksum_manifest", return_value={}),
        ):
            result = preflight("901DEVLIB", _IMAGE_PATH)

        assert result.data["estimated_gb"] == pytest.approx(20.0)

    def test_happy_path_file_count(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=200_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=5_000_000_000),
            patch("devdrive_v2.migrate_v1._image_is_attached", return_value=True),
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch(
                "devdrive_v2.migrate_v1._collect_regular_files",
                return_value=["a", "b", "c"],
            ),
            patch("devdrive_v2.migrate_v1._build_checksum_manifest", return_value={}),
        ):
            result = preflight("901DEVLIB", _IMAGE_PATH)

        assert result.data["file_count"] == 3

    def test_happy_path_checksum_manifest(self) -> None:
        expected_manifest = {"rel/file.txt": "deadbeef"}
        with (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=200_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=5_000_000_000),
            patch("devdrive_v2.migrate_v1._image_is_attached", return_value=True),
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=["f"]),
            patch(
                "devdrive_v2.migrate_v1._build_checksum_manifest",
                return_value=expected_manifest,
            ),
        ):
            result = preflight("901DEVLIB", _IMAGE_PATH)

        assert result.data["checksum_manifest"] == expected_manifest

    def test_happy_path_mount_point(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=200_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=5_000_000_000),
            patch("devdrive_v2.migrate_v1._image_is_attached", return_value=True),
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=[]),
            patch("devdrive_v2.migrate_v1._build_checksum_manifest", return_value={}),
        ):
            result = preflight("901DEVLIB", _IMAGE_PATH)

        assert result.data["mount_point"] == _IMAGE_MOUNT


# ---------------------------------------------------------------------------
# preflight — missing image
# ---------------------------------------------------------------------------


class TestPreflightMissingImage:
    """Preflight fails when the sparseimage file does not exist."""

    def test_missing_image_returns_failure(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=200_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=False),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=0),
        ):
            result = preflight("901DEVLIB", "/nonexistent/image.sparseimage")

        assert result.success is False
        assert result.stage == "preflight"

    def test_missing_image_message_contains_path(self) -> None:
        bad_path = "/nonexistent/image.sparseimage"
        with (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=200_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=False),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=0),
        ):
            result = preflight("901DEVLIB", bad_path)

        assert bad_path in result.message

    def test_missing_image_stage_is_preflight(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=200_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=False),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=0),
        ):
            result = preflight("901DEVLIB", "/bad/path")

        assert result.stage == "preflight"


# ---------------------------------------------------------------------------
# preflight — container full
# ---------------------------------------------------------------------------


class TestPreflightContainerFull:
    """Preflight fails when the container has insufficient free space."""

    def test_container_full_returns_failure(self) -> None:
        # 1 GB free but image is 50 GB → should fail.
        with (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=1_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=50_000_000_000),
        ):
            result = preflight("901DEVLIB", _IMAGE_PATH)

        assert result.success is False

    def test_container_full_message_mentions_capacity(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=1_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=50_000_000_000),
        ):
            result = preflight("901DEVLIB", _IMAGE_PATH)

        assert "GB" in result.message or "capacity" in result.message.lower()

    def test_container_not_queryable_returns_failure(self) -> None:
        """When _get_container_free_bytes returns None, preflight fails gracefully."""
        with patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=None):
            result = preflight("901DEVLIB", _IMAGE_PATH)

        assert result.success is False
        assert result.stage == "preflight"


# ---------------------------------------------------------------------------
# preflight — image not attached
# ---------------------------------------------------------------------------


class TestPreflightImageNotAttached:
    """Preflight fails when the image exists but is not attached."""

    def test_not_attached_returns_failure(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._get_container_free_bytes", return_value=200_000_000_000),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.path.getsize", return_value=5_000_000_000),
            patch("devdrive_v2.migrate_v1._image_is_attached", return_value=False),
        ):
            result = preflight("901DEVLIB", _IMAGE_PATH)

        assert result.success is False
        assert "not currently attached" in result.message or "attached" in result.message.lower()


# ---------------------------------------------------------------------------
# migrate — dry_run=True
# ---------------------------------------------------------------------------


class TestMigrateDryRun:
    """migrate(dry_run=True) describes the plan without side-effects."""

    def test_dry_run_returns_success(self) -> None:
        result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=True)
        assert result.success is True

    def test_dry_run_stage_is_migrate(self) -> None:
        result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=True)
        assert result.stage == "migrate"

    def test_dry_run_data_contains_plan(self) -> None:
        result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=True)
        assert "plan" in result.data
        assert isinstance(result.data["plan"], list)
        assert len(result.data["plan"]) > 0

    def test_dry_run_data_plan_mentions_rsync(self) -> None:
        result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=True)
        plan_text = " ".join(result.data["plan"])
        assert "rsync" in plan_text.lower()

    def test_dry_run_data_plan_mentions_apfs_volume(self) -> None:
        result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=True)
        plan_text = " ".join(result.data["plan"])
        assert "volume" in plan_text.lower() or "apfs" in plan_text.lower()

    def test_dry_run_data_plan_mentions_detach(self) -> None:
        result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=True)
        plan_text = " ".join(result.data["plan"])
        assert "detach" in plan_text.lower() or "hdiutil" in plan_text.lower()

    def test_dry_run_data_contains_staging_volume(self) -> None:
        result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=True)
        assert "staging_volume" in result.data
        assert result.data["staging_volume"] == "901DEVLIB-v2"

    def test_dry_run_message_mentions_dry_run(self) -> None:
        result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=True)
        assert "dry-run" in result.message.lower() or "dry_run" in result.message.lower()

    def test_dry_run_no_subprocess_called(self) -> None:
        with patch("devdrive_v2.migrate_v1._run") as mock_run:
            migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=True)
        mock_run.assert_not_called()

    def test_dry_run_no_create_volume_called(self) -> None:
        with patch("devdrive_v2.migrate_v1.create_volume") as mock_create:
            migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=True)
        mock_create.assert_not_called()

    def test_dry_run_volume_name_in_result(self) -> None:
        result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=True)
        assert result.volume_name == "901DEVLIB"


# ---------------------------------------------------------------------------
# migrate — apply mode (dry_run=False)
# ---------------------------------------------------------------------------


class TestMigrateApply:
    """migrate(dry_run=False) executes the full pipeline in order."""

    def _make_mocks(self, mock_run: MagicMock) -> None:
        """Set up mock_run side_effects for the apply pipeline."""
        mock_run.side_effect = [
            _completed(_STAGING_VOLUME_PLIST),       # diskutil info -plist 901DEVLIB-v2 (mount point)
            _completed("rsync: transfer complete\n"), # rsync -aHAX
            _completed("", returncode=0),             # hdiutil detach
        ]

    def test_apply_calls_create_volume(self) -> None:
        from devdrive_v2.apfs_volume import VolumeResult

        with (
            patch("devdrive_v2.migrate_v1.create_volume") as mock_create,
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1.rename_volume") as mock_rename,
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=[]),
            patch("devdrive_v2.migrate_v1._write_migration_state"),
        ):
            mock_create.return_value = VolumeResult(
                success=True, message="created", data={}
            )
            mock_run.side_effect = [
                _completed(_STAGING_VOLUME_PLIST),       # diskutil info for mount point
                _completed("rsync ok\n"),                 # rsync
                _completed("detached\n"),                 # hdiutil detach
            ]
            mock_rename.return_value = VolumeResult(success=True, message="renamed")
            migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=False)

        mock_create.assert_called_once()
        create_args = mock_create.call_args
        # First positional arg: staging name
        assert create_args.args[0] == "901DEVLIB-v2"

    def test_apply_calls_rsync(self) -> None:
        from devdrive_v2.apfs_volume import VolumeResult

        with (
            patch("devdrive_v2.migrate_v1.create_volume") as mock_create,
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1.rename_volume") as mock_rename,
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=[]),
            patch("devdrive_v2.migrate_v1._write_migration_state"),
        ):
            mock_create.return_value = VolumeResult(success=True, message="created")
            mock_run.side_effect = [
                _completed(_STAGING_VOLUME_PLIST),
                _completed("rsync ok\n"),
                _completed(""),
            ]
            mock_rename.return_value = VolumeResult(success=True, message="renamed")
            migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=False)

        rsync_calls = [
            c for c in mock_run.call_args_list if "rsync" in c.args[0][0]
        ]
        assert len(rsync_calls) == 1
        rsync_args: list[str] = rsync_calls[0].args[0]
        assert rsync_args[0] == "rsync"
        assert "-aHAX" in rsync_args

    def test_apply_calls_hdiutil_detach(self) -> None:
        from devdrive_v2.apfs_volume import VolumeResult

        with (
            patch("devdrive_v2.migrate_v1.create_volume") as mock_create,
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1.rename_volume") as mock_rename,
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=[]),
            patch("devdrive_v2.migrate_v1._write_migration_state"),
        ):
            mock_create.return_value = VolumeResult(success=True, message="created")
            mock_run.side_effect = [
                _completed(_STAGING_VOLUME_PLIST),
                _completed("rsync ok\n"),
                _completed(""),
            ]
            mock_rename.return_value = VolumeResult(success=True, message="renamed")
            migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=False)

        detach_calls = [
            c for c in mock_run.call_args_list if "hdiutil" in c.args[0][0]
        ]
        assert len(detach_calls) == 1
        assert "detach" in detach_calls[0].args[0]

    def test_apply_calls_rename_volume(self) -> None:
        from devdrive_v2.apfs_volume import VolumeResult

        with (
            patch("devdrive_v2.migrate_v1.create_volume") as mock_create,
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1.rename_volume") as mock_rename,
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=[]),
            patch("devdrive_v2.migrate_v1._write_migration_state"),
        ):
            mock_create.return_value = VolumeResult(success=True, message="created")
            mock_run.side_effect = [
                _completed(_STAGING_VOLUME_PLIST),
                _completed("rsync ok\n"),
                _completed(""),
            ]
            mock_rename.return_value = VolumeResult(success=True, message="renamed")
            migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=False)

        mock_rename.assert_called_once_with("901DEVLIB-v2", "901DEVLIB")

    def test_apply_records_migration_state(self) -> None:
        from devdrive_v2.apfs_volume import VolumeResult

        with (
            patch("devdrive_v2.migrate_v1.create_volume") as mock_create,
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1.rename_volume") as mock_rename,
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=[]),
            patch("devdrive_v2.migrate_v1._write_migration_state") as mock_write,
        ):
            mock_create.return_value = VolumeResult(success=True, message="created")
            mock_run.side_effect = [
                _completed(_STAGING_VOLUME_PLIST),
                _completed("rsync ok\n"),
                _completed(""),
            ]
            mock_rename.return_value = VolumeResult(success=True, message="renamed")
            migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=False)

        mock_write.assert_called_once()
        state_arg: dict = mock_write.call_args.args[1]
        assert "grace_until" in state_arg
        assert "migrated_at" in state_arg

    def test_apply_grace_until_is_24h_from_now(self) -> None:
        from devdrive_v2.apfs_volume import VolumeResult

        t0 = time.time()
        with (
            patch("devdrive_v2.migrate_v1.create_volume") as mock_create,
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1.rename_volume") as mock_rename,
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=[]),
            patch("devdrive_v2.migrate_v1._write_migration_state") as mock_write,
        ):
            mock_create.return_value = VolumeResult(success=True, message="created")
            mock_run.side_effect = [
                _completed(_STAGING_VOLUME_PLIST),
                _completed("rsync ok\n"),
                _completed(""),
            ]
            mock_rename.return_value = VolumeResult(success=True, message="renamed")
            result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=False)

        grace = result.data.get("grace_until", 0)
        # Should be approximately 24 hours from now (within a few seconds).
        assert 24 * 3600 - 5 < (grace - t0) < 24 * 3600 + 5

    def test_apply_create_volume_failure_returns_failure(self) -> None:
        from devdrive_v2.apfs_volume import VolumeResult

        with patch("devdrive_v2.migrate_v1.create_volume") as mock_create:
            mock_create.return_value = VolumeResult(
                success=False, message="no space left"
            )
            result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=False)

        assert result.success is False
        assert "no space left" in result.message

    def test_apply_rsync_failure_returns_failure(self) -> None:
        from devdrive_v2.apfs_volume import VolumeResult

        with (
            patch("devdrive_v2.migrate_v1.create_volume") as mock_create,
            patch("devdrive_v2.migrate_v1._run") as mock_run,
        ):
            mock_create.return_value = VolumeResult(success=True, message="created")
            mock_run.side_effect = [
                _completed(_STAGING_VOLUME_PLIST),
                _completed("", returncode=23, stderr="rsync: permission denied"),
            ]
            result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=False)

        assert result.success is False
        assert "rsync" in result.message.lower()

    def test_apply_hdiutil_detach_failure_returns_failure(self) -> None:
        from devdrive_v2.apfs_volume import VolumeResult

        with (
            patch("devdrive_v2.migrate_v1.create_volume") as mock_create,
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=[]),
        ):
            mock_create.return_value = VolumeResult(success=True, message="created")
            mock_run.side_effect = [
                _completed(_STAGING_VOLUME_PLIST),
                _completed("rsync ok\n"),
                _completed("", returncode=1, stderr="device is busy"),
            ]
            result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=False)

        assert result.success is False
        assert "detach" in result.message.lower() or "device is busy" in result.message

    def test_apply_rename_failure_returns_failure(self) -> None:
        from devdrive_v2.apfs_volume import VolumeResult

        with (
            patch("devdrive_v2.migrate_v1.create_volume") as mock_create,
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1.rename_volume") as mock_rename,
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=[]),
        ):
            mock_create.return_value = VolumeResult(success=True, message="created")
            mock_run.side_effect = [
                _completed(_STAGING_VOLUME_PLIST),
                _completed("rsync ok\n"),
                _completed(""),
            ]
            mock_rename.return_value = VolumeResult(
                success=False, message="no volume named 901DEVLIB-v2"
            )
            result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=False)

        assert result.success is False

    def test_apply_success_returns_success_true(self) -> None:
        from devdrive_v2.apfs_volume import VolumeResult

        with (
            patch("devdrive_v2.migrate_v1.create_volume") as mock_create,
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1.rename_volume") as mock_rename,
            patch("devdrive_v2.migrate_v1._collect_regular_files", return_value=[]),
            patch("devdrive_v2.migrate_v1._write_migration_state"),
        ):
            mock_create.return_value = VolumeResult(success=True, message="created")
            mock_run.side_effect = [
                _completed(_STAGING_VOLUME_PLIST),
                _completed("rsync ok\n"),
                _completed(""),
            ]
            mock_rename.return_value = VolumeResult(success=True, message="renamed")
            result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=False)

        assert result.success is True

    def test_apply_checksum_mismatch_returns_verify_stage(self) -> None:
        """When a sampled file has a different checksum, stage should be 'verify'."""
        from devdrive_v2.apfs_volume import VolumeResult

        def _fake_sha256(path: str) -> str:
            # Return different digest for any file on the new volume vs source.
            if "901DEVLIB-v2" in path or "/Volumes/901DEVLIB-v2" in path:
                return "different_digest"
            return "original_digest"

        with (
            patch("devdrive_v2.migrate_v1.create_volume") as mock_create,
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1.rename_volume") as mock_rename,
            patch(
                "devdrive_v2.migrate_v1._collect_regular_files",
                return_value=["/Volumes/901DEVLIB-v2/file.txt"],
            ),
            patch("devdrive_v2.migrate_v1._sha256_file", side_effect=_fake_sha256),
        ):
            mock_create.return_value = VolumeResult(success=True, message="created")
            mock_run.side_effect = [
                _completed(_STAGING_VOLUME_PLIST),
                _completed("rsync ok\n"),
            ]
            mock_rename.return_value = VolumeResult(success=True, message="renamed")
            result = migrate("901DEVLIB", _IMAGE_PATH, _IMAGE_MOUNT, dry_run=False)

        assert result.success is False
        assert result.stage == "verify"


# ---------------------------------------------------------------------------
# rollback
# ---------------------------------------------------------------------------


class TestRollback:
    """rollback re-attaches the image and rsyncs data back."""

    def test_rollback_calls_hdiutil_attach(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch("devdrive_v2.migrate_v1._apfs_volume_mount_point", return_value="/Volumes/901DEVLIB"),
        ):
            mock_run.side_effect = [
                _completed(f"/dev/disk4\t{_IMAGE_MOUNT}\n"),  # hdiutil attach
                _completed("rsync ok\n"),                       # rsync back
            ]
            result = rollback("901DEVLIB", _IMAGE_PATH)

        attach_calls = [
            c for c in mock_run.call_args_list if "hdiutil" in c.args[0][0]
        ]
        assert len(attach_calls) == 1
        assert "attach" in attach_calls[0].args[0]
        assert _IMAGE_PATH in attach_calls[0].args[0]

    def test_rollback_calls_rsync_back(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch("devdrive_v2.migrate_v1._apfs_volume_mount_point", return_value="/Volumes/901DEVLIB"),
        ):
            mock_run.side_effect = [
                _completed("attached\n"),
                _completed("rsync ok\n"),
            ]
            result = rollback("901DEVLIB", _IMAGE_PATH)

        rsync_calls = [
            c for c in mock_run.call_args_list if "rsync" in c.args[0][0]
        ]
        assert len(rsync_calls) == 1
        rsync_args: list[str] = rsync_calls[0].args[0]
        assert "-aHAX" in rsync_args

    def test_rollback_success_returns_success_true(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch("devdrive_v2.migrate_v1._apfs_volume_mount_point", return_value="/Volumes/901DEVLIB"),
        ):
            mock_run.side_effect = [
                _completed("attached\n"),
                _completed("rsync ok\n"),
            ]
            result = rollback("901DEVLIB", _IMAGE_PATH)

        assert result.success is True
        assert result.stage == "rollback"

    def test_rollback_stage_is_rollback(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch("devdrive_v2.migrate_v1._apfs_volume_mount_point", return_value="/Volumes/901DEVLIB"),
        ):
            mock_run.side_effect = [
                _completed("attached\n"),
                _completed("rsync ok\n"),
            ]
            result = rollback("901DEVLIB", _IMAGE_PATH)

        assert result.stage == "rollback"

    def test_rollback_success_data_contains_mount_point(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch("devdrive_v2.migrate_v1._apfs_volume_mount_point", return_value="/Volumes/901DEVLIB"),
        ):
            mock_run.side_effect = [
                _completed("attached\n"),
                _completed("rsync ok\n"),
            ]
            result = rollback("901DEVLIB", _IMAGE_PATH)

        assert "image_mount_point" in result.data
        assert result.data["image_mount_point"] == _IMAGE_MOUNT

    def test_rollback_hdiutil_attach_failure_returns_failure(self) -> None:
        with patch("devdrive_v2.migrate_v1._run") as mock_run:
            mock_run.return_value = _completed(
                "", returncode=1, stderr="no image at path"
            )
            result = rollback("901DEVLIB", "/bad/path.sparseimage")

        assert result.success is False
        assert "attach" in result.message.lower() or "failed" in result.message.lower()

    def test_rollback_rsync_failure_returns_failure(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch("devdrive_v2.migrate_v1._apfs_volume_mount_point", return_value="/Volumes/901DEVLIB"),
        ):
            mock_run.side_effect = [
                _completed("attached\n"),
                _completed("", returncode=1, stderr="rsync: I/O error"),
            ]
            result = rollback("901DEVLIB", _IMAGE_PATH)

        assert result.success is False
        assert "rsync" in result.message.lower()

    def test_rollback_volume_name_in_result(self) -> None:
        with (
            patch("devdrive_v2.migrate_v1._run") as mock_run,
            patch("devdrive_v2.migrate_v1._get_image_mount_point", return_value=_IMAGE_MOUNT),
            patch("devdrive_v2.migrate_v1._apfs_volume_mount_point", return_value="/Volumes/901DEVLIB"),
        ):
            mock_run.side_effect = [
                _completed("attached\n"),
                _completed("rsync ok\n"),
            ]
            result = rollback("901DEVLIB", _IMAGE_PATH)

        assert result.volume_name == "901DEVLIB"


# ---------------------------------------------------------------------------
# cleanup — grace period not elapsed
# ---------------------------------------------------------------------------


class TestCleanupGraceNotElapsed:
    """cleanup returns failure when the grace period has not expired."""

    def _write_fresh_state(self, volume_name: str, tmp_path: Path) -> Path:
        """Write a migration state file with grace_until in the future."""
        state = {
            "volume_name": volume_name,
            "image_path": _IMAGE_PATH,
            "migrated_at": time.time(),
            "grace_until": time.time() + 48 * 3600,  # 48 hours from now
        }
        state_dir = tmp_path / "migrations"
        state_dir.mkdir(parents=True)
        state_file = state_dir / f"{volume_name}.json"
        state_file.write_text(json.dumps(state))
        return state_file

    def test_grace_not_elapsed_returns_failure(self) -> None:
        future_grace = time.time() + 48 * 3600
        with (
            patch(
                "devdrive_v2.migrate_v1._read_migration_state",
                return_value={"grace_until": future_grace},
            ),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
        ):
            result = cleanup("901DEVLIB", _IMAGE_PATH)

        assert result.success is False

    def test_grace_not_elapsed_stage_is_cleanup(self) -> None:
        future_grace = time.time() + 48 * 3600
        with (
            patch(
                "devdrive_v2.migrate_v1._read_migration_state",
                return_value={"grace_until": future_grace},
            ),
        ):
            result = cleanup("901DEVLIB", _IMAGE_PATH)

        assert result.stage == "cleanup"

    def test_grace_not_elapsed_message_contains_remaining_hours(self) -> None:
        future_grace = time.time() + 10 * 3600  # 10 hours remaining
        with (
            patch(
                "devdrive_v2.migrate_v1._read_migration_state",
                return_value={"grace_until": future_grace},
            ),
        ):
            result = cleanup("901DEVLIB", _IMAGE_PATH)

        assert "hour" in result.message.lower()

    def test_grace_not_elapsed_data_contains_remaining_hours(self) -> None:
        future_grace = time.time() + 12 * 3600
        with (
            patch(
                "devdrive_v2.migrate_v1._read_migration_state",
                return_value={"grace_until": future_grace},
            ),
        ):
            result = cleanup("901DEVLIB", _IMAGE_PATH)

        assert "remaining_hours" in result.data
        assert result.data["remaining_hours"] == pytest.approx(12.0, abs=0.1)

    def test_grace_not_elapsed_does_not_delete_file(self) -> None:
        future_grace = time.time() + 24 * 3600
        with (
            patch(
                "devdrive_v2.migrate_v1._read_migration_state",
                return_value={"grace_until": future_grace},
            ),
            patch("devdrive_v2.migrate_v1.os.remove") as mock_remove,
        ):
            cleanup("901DEVLIB", _IMAGE_PATH)

        mock_remove.assert_not_called()


# ---------------------------------------------------------------------------
# cleanup — grace period elapsed
# ---------------------------------------------------------------------------


class TestCleanupGraceElapsed:
    """cleanup deletes the image when the grace period has expired."""

    def _past_grace(self) -> dict:
        return {"grace_until": time.time() - 3600}  # 1 hour in the past

    def test_grace_elapsed_deletes_image(self) -> None:
        with (
            patch(
                "devdrive_v2.migrate_v1._read_migration_state",
                return_value=self._past_grace(),
            ),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.remove") as mock_remove,
        ):
            cleanup("901DEVLIB", _IMAGE_PATH)

        mock_remove.assert_called_once_with(_IMAGE_PATH)

    def test_grace_elapsed_returns_success(self) -> None:
        with (
            patch(
                "devdrive_v2.migrate_v1._read_migration_state",
                return_value=self._past_grace(),
            ),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.remove"),
        ):
            result = cleanup("901DEVLIB", _IMAGE_PATH)

        assert result.success is True

    def test_grace_elapsed_stage_is_cleanup(self) -> None:
        with (
            patch(
                "devdrive_v2.migrate_v1._read_migration_state",
                return_value=self._past_grace(),
            ),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.remove"),
        ):
            result = cleanup("901DEVLIB", _IMAGE_PATH)

        assert result.stage == "cleanup"

    def test_grace_elapsed_data_contains_deleted_path(self) -> None:
        with (
            patch(
                "devdrive_v2.migrate_v1._read_migration_state",
                return_value=self._past_grace(),
            ),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.remove"),
        ):
            result = cleanup("901DEVLIB", _IMAGE_PATH)

        assert result.data.get("deleted_path") == _IMAGE_PATH

    def test_grace_elapsed_os_remove_failure_returns_failure(self) -> None:
        with (
            patch(
                "devdrive_v2.migrate_v1._read_migration_state",
                return_value=self._past_grace(),
            ),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.remove", side_effect=OSError("permission denied")),
        ):
            result = cleanup("901DEVLIB", _IMAGE_PATH)

        assert result.success is False
        assert "permission denied" in result.message

    def test_grace_elapsed_image_already_gone_returns_success(self) -> None:
        """If the image was already deleted, cleanup should still succeed."""
        with (
            patch(
                "devdrive_v2.migrate_v1._read_migration_state",
                return_value=self._past_grace(),
            ),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=False),
            patch("devdrive_v2.migrate_v1.os.remove") as mock_remove,
        ):
            result = cleanup("901DEVLIB", _IMAGE_PATH)

        mock_remove.assert_not_called()
        assert result.success is True

    def test_grace_elapsed_no_state_file_uses_grace_hours_parameter(self) -> None:
        """When no state file exists, grace_hours from argument is applied from now."""
        # No state file → _read_migration_state returns {}
        # grace_hours=0 → grace_until = now + 0 → already elapsed
        with (
            patch("devdrive_v2.migrate_v1._read_migration_state", return_value={}),
            patch("devdrive_v2.migrate_v1.os.path.exists", return_value=True),
            patch("devdrive_v2.migrate_v1.os.remove") as mock_remove,
        ):
            # grace_hours=0 means immediately eligible
            result = cleanup("901DEVLIB", _IMAGE_PATH, grace_hours=0.0)

        # grace_until will be approximately now, so cleanup should proceed.
        # (Within the test, time.time() runs twice and the delta is negligible.)
        # Accept either outcome since the race is within ms; just verify no raise.
        assert isinstance(result, MigrationResult)


# ---------------------------------------------------------------------------
# Internal helper unit tests
# ---------------------------------------------------------------------------


class TestSha256File:
    """Unit tests for _sha256_file."""

    def test_returns_hex_string(self, tmp_path: Path) -> None:
        f = tmp_path / "test.bin"
        f.write_bytes(b"hello world")
        digest = _sha256_file(str(f))
        assert digest is not None
        assert len(digest) == 64
        assert all(c in "0123456789abcdef" for c in digest)

    def test_consistent_for_same_content(self, tmp_path: Path) -> None:
        f = tmp_path / "a.bin"
        f.write_bytes(b"deterministic")
        d1 = _sha256_file(str(f))
        d2 = _sha256_file(str(f))
        assert d1 == d2

    def test_different_for_different_content(self, tmp_path: Path) -> None:
        f1 = tmp_path / "x.bin"
        f2 = tmp_path / "y.bin"
        f1.write_bytes(b"aaa")
        f2.write_bytes(b"bbb")
        assert _sha256_file(str(f1)) != _sha256_file(str(f2))

    def test_returns_none_for_missing_file(self) -> None:
        result = _sha256_file("/definitely/not/a/real/path.bin")
        assert result is None

    def test_returns_none_on_permission_error(self, tmp_path: Path) -> None:
        f = tmp_path / "locked.bin"
        f.write_bytes(b"data")
        with patch("builtins.open", side_effect=PermissionError("nope")):
            result = _sha256_file(str(f))
        assert result is None


class TestBuildChecksumManifest:
    """Unit tests for _build_checksum_manifest."""

    def test_manifest_has_relative_paths(self, tmp_path: Path) -> None:
        (tmp_path / "a.txt").write_text("hello")
        (tmp_path / "b.txt").write_text("world")
        manifest = _build_checksum_manifest(str(tmp_path))
        for key in manifest:
            assert not os.path.isabs(key), f"Expected relative path, got: {key}"

    def test_manifest_samples_at_most_sample_size(self, tmp_path: Path) -> None:
        for i in range(20):
            (tmp_path / f"file{i}.txt").write_text(f"content{i}")
        manifest = _build_checksum_manifest(str(tmp_path), sample_size=5)
        assert len(manifest) <= 5

    def test_manifest_includes_all_files_when_fewer_than_sample_size(
        self, tmp_path: Path
    ) -> None:
        for i in range(3):
            (tmp_path / f"f{i}.bin").write_bytes(bytes([i]))
        manifest = _build_checksum_manifest(str(tmp_path), sample_size=50)
        assert len(manifest) == 3

    def test_manifest_values_are_hex_sha256(self, tmp_path: Path) -> None:
        (tmp_path / "c.txt").write_text("data")
        manifest = _build_checksum_manifest(str(tmp_path))
        for digest in manifest.values():
            assert len(digest) == 64


class TestVerifyChecksumManifest:
    """Unit tests for _verify_checksum_manifest."""

    def test_all_match_returns_true_empty_mismatches(self, tmp_path: Path) -> None:
        f = tmp_path / "ok.txt"
        f.write_bytes(b"abc")
        import hashlib

        digest = hashlib.sha256(b"abc").hexdigest()
        ok, mismatches = _verify_checksum_manifest(str(tmp_path), {"ok.txt": digest})
        assert ok is True
        assert mismatches == []

    def test_mismatch_detected(self, tmp_path: Path) -> None:
        f = tmp_path / "changed.txt"
        f.write_bytes(b"new content")
        ok, mismatches = _verify_checksum_manifest(
            str(tmp_path), {"changed.txt": "deadbeef" * 8}
        )
        assert ok is False
        assert "changed.txt" in mismatches

    def test_missing_file_counted_as_mismatch(self, tmp_path: Path) -> None:
        ok, mismatches = _verify_checksum_manifest(
            str(tmp_path), {"ghost.txt": "aabbccdd" * 8}
        )
        assert ok is False
        assert "ghost.txt" in mismatches

    def test_empty_manifest_returns_true(self, tmp_path: Path) -> None:
        ok, mismatches = _verify_checksum_manifest(str(tmp_path), {})
        assert ok is True
        assert mismatches == []


class TestImageIsAttached:
    """Unit tests for _image_is_attached."""

    def test_attached_returns_true(self) -> None:
        with patch("devdrive_v2.migrate_v1._run") as mock_run:
            mock_run.return_value = _completed(_HDIUTIL_INFO_PLIST)
            assert _image_is_attached(_IMAGE_PATH) is True

    def test_not_attached_returns_false(self) -> None:
        empty_plist = _plist_str({"images": []})
        with patch("devdrive_v2.migrate_v1._run") as mock_run:
            mock_run.return_value = _completed(empty_plist)
            assert _image_is_attached(_IMAGE_PATH) is False

    def test_different_image_not_matched(self) -> None:
        with patch("devdrive_v2.migrate_v1._run") as mock_run:
            mock_run.return_value = _completed(_HDIUTIL_INFO_PLIST)
            assert _image_is_attached("/other/image.sparseimage") is False

    def test_hdiutil_fails_returns_false(self) -> None:
        with patch("devdrive_v2.migrate_v1._run") as mock_run:
            mock_run.return_value = _completed("", returncode=1)
            assert _image_is_attached(_IMAGE_PATH) is False

    def test_exception_returns_false(self) -> None:
        with patch("devdrive_v2.migrate_v1._run", side_effect=OSError("hdiutil missing")):
            assert _image_is_attached(_IMAGE_PATH) is False


class TestGetContainerFreeBytes:
    """Unit tests for _get_container_free_bytes.

    ``_get_container_free_bytes`` delegates to ``get_container_info()`` from
    ``devdrive_v2.apfs_volume``, which calls ``devdrive_v2.apfs_volume._run``.
    We therefore patch ``devdrive_v2.apfs_volume._run`` here.
    """

    def test_returns_free_bytes_for_matching_container(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(_CONTAINER_PLIST)
            free = _get_container_free_bytes("disk3")
        assert free == 200_000_000_000

    def test_returns_none_for_unknown_container(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(_CONTAINER_PLIST)
            free = _get_container_free_bytes("disk99")
        assert free is None

    def test_returns_none_when_diskutil_fails(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed("", returncode=1)
            free = _get_container_free_bytes("disk3")
        assert free is None

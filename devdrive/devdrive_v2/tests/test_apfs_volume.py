"""Tests for devdrive_v2.apfs_volume — all subprocess calls are mocked.

Run with:
    PYTHONPATH=lib pytest lib/devdrive_v2/tests/test_apfs_volume.py -v
"""

from __future__ import annotations

import plistlib
import subprocess
from typing import Any
from unittest.mock import call, patch

import pytest

from devdrive_v2.apfs_volume import (
    VolumeResult,
    _gb_to_bytes,
    _parse_snapshot_output,
    create_volume,
    delete_volume,
    get_container_info,
    get_volume_info,
    list_snapshots,
    rename_volume,
    set_quota,
    take_snapshot,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _completed(
    stdout: str = "", stderr: str = "", returncode: int = 0
) -> subprocess.CompletedProcess[str]:
    """Build a fake CompletedProcess for use in mock return values."""
    return subprocess.CompletedProcess(
        args=[], returncode=returncode, stdout=stdout, stderr=stderr
    )


def _plist_str(data: dict[str, Any]) -> str:
    """Encode *data* as a plist XML string."""
    return plistlib.dumps(data, fmt=plistlib.FMT_XML).decode()


# Plist returned by "diskutil info -plist disk3" (container check)
_CONTAINER_INFO_PLIST = _plist_str(
    {"DeviceIdentifier": "disk3", "Content": "Apple_APFS"}
)

# Plist returned by "diskutil info -plist MYVOLUME"
_VOLUME_INFO_PLIST = _plist_str(
    {
        "DeviceIdentifier": "disk3s5",
        "VolumeName": "MYVOLUME",
        "MountPoint": "/Volumes/MYVOLUME",
        "TotalSize": 50_000_000_000,
        "FreeSpace": 20_000_000_000,
        "FilesystemType": "apfs",
    }
)

# Plist returned by "diskutil apfs list -plist"
_APFS_LIST_PLIST = _plist_str(
    {
        "Containers": [
            {
                "ContainerReference": "disk3",
                "Designation": "Physical",
                "CapacityCeiling": 500_000_000_000,
                "CapacityFree": 120_000_000_000,
                "Volumes": [
                    {
                        "Name": "MYVOLUME",
                        "DeviceIdentifier": "disk3s5",
                        "MountPoint": "/Volumes/MYVOLUME",
                        "Roles": ["Data"],
                        "CapacityCeiling": 50_000_000_000,
                        "CapacityQuota": 50_000_000_000,
                    }
                ],
            }
        ]
    }
)

_SNAPSHOT_OUTPUT = """\
+-- Snapshot: com.apple.TimeMachine.2024-01-15-120000
|   XID: 12345
|   Created: 2024-01-15 12:00:00 +0000
+-- Snapshot: com.apple.TimeMachine.2024-01-16-080000
|   XID: 12399
|   Created: 2024-01-16 08:00:00 +0000
"""


# ---------------------------------------------------------------------------
# _gb_to_bytes utility
# ---------------------------------------------------------------------------


class TestGbToBytes:
    def test_integer_gb(self) -> None:
        assert _gb_to_bytes(50) == 50_000_000_000

    def test_fractional_gb(self) -> None:
        assert _gb_to_bytes(1.5) == 1_500_000_000

    def test_zero(self) -> None:
        assert _gb_to_bytes(0) == 0


# ---------------------------------------------------------------------------
# _parse_snapshot_output utility
# ---------------------------------------------------------------------------


class TestParseSnapshotOutput:
    def test_parses_two_snapshots(self) -> None:
        snapshots = _parse_snapshot_output(_SNAPSHOT_OUTPUT)
        assert len(snapshots) == 2
        assert snapshots[0]["name"] == "com.apple.TimeMachine.2024-01-15-120000"
        assert snapshots[0]["date"] == "2024-01-15 12:00:00 +0000"
        assert snapshots[1]["name"] == "com.apple.TimeMachine.2024-01-16-080000"

    def test_empty_output(self) -> None:
        assert _parse_snapshot_output("") == []

    def test_no_snapshots(self) -> None:
        assert _parse_snapshot_output("No snapshots found.\n") == []

    def test_snapshot_without_created(self) -> None:
        output = "+-- Snapshot: com.apple.TimeMachine.2024-01-15-120000\n|   XID: 999\n"
        snapshots = _parse_snapshot_output(output)
        assert len(snapshots) == 1
        assert snapshots[0]["date"] == ""


# ---------------------------------------------------------------------------
# create_volume
# ---------------------------------------------------------------------------


class TestCreateVolume:
    def test_happy_path(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            # container check, then addVolume
            mock_run.side_effect = [
                _completed(_CONTAINER_INFO_PLIST),          # diskutil info disk3
                _completed("Created new APFS Volume\n"),    # addVolume
            ]
            result = create_volume("MYVOLUME", quota_gb=50, container="disk3")

        assert result.success is True
        assert "MYVOLUME" in result.message
        assert mock_run.call_count == 2
        # Verify the addVolume call has the expected structure
        add_call_args: list[str] = mock_run.call_args_list[1][0][0]
        assert add_call_args[:4] == ["diskutil", "apfs", "addVolume", "disk3"]
        assert "MYVOLUME" in add_call_args
        assert "-quota" in add_call_args
        assert str(_gb_to_bytes(50)) in add_call_args
        assert "-role" in add_call_args
        assert "U" in add_call_args

    def test_happy_path_with_reserve(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = [
                _completed(_CONTAINER_INFO_PLIST),
                _completed("Created new APFS Volume\n"),
            ]
            result = create_volume("MYVOLUME", quota_gb=50, reserve_gb=10, container="disk3")

        assert result.success is True
        add_call_args = mock_run.call_args_list[1][0][0]
        assert "-reserve" in add_call_args
        assert str(_gb_to_bytes(10)) in add_call_args

    def test_no_reserve_flag_when_zero(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = [
                _completed(_CONTAINER_INFO_PLIST),
                _completed("ok"),
            ]
            result = create_volume("VOL", quota_gb=10, reserve_gb=0, container="disk3")

        assert result.success is True
        add_call_args = mock_run.call_args_list[1][0][0]
        assert "-reserve" not in add_call_args

    # --- Validation failures ---

    def test_empty_name(self) -> None:
        result = create_volume("", quota_gb=10)
        assert result.success is False
        assert "empty" in result.message.lower()

    def test_whitespace_name(self) -> None:
        result = create_volume("   ", quota_gb=10)
        assert result.success is False

    def test_zero_quota(self) -> None:
        result = create_volume("VOL", quota_gb=0)
        assert result.success is False
        assert "positive" in result.message.lower()

    def test_negative_quota(self) -> None:
        result = create_volume("VOL", quota_gb=-5)
        assert result.success is False

    def test_negative_reserve(self) -> None:
        result = create_volume("VOL", quota_gb=10, reserve_gb=-1)
        assert result.success is False
        assert "negative" in result.message.lower()

    def test_empty_container(self) -> None:
        result = create_volume("VOL", quota_gb=10, container="")
        assert result.success is False

    # --- Container not found ---

    def test_container_not_found(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed("", returncode=1)
            result = create_volume("VOL", quota_gb=10, container="disk99")

        assert result.success is False
        assert "disk99" in result.message

    def test_container_check_raises(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = FileNotFoundError("diskutil not found")
            result = create_volume("VOL", quota_gb=10, container="disk3")

        assert result.success is False

    # --- diskutil addVolume fails ---

    def test_diskutil_nonzero_returncode(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = [
                _completed(_CONTAINER_INFO_PLIST),
                _completed("", stderr="No space left on device", returncode=1),
            ]
            result = create_volume("VOL", quota_gb=500, container="disk3")

        assert result.success is False
        assert "No space left" in result.message

    def test_diskutil_raises_exception(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = [
                _completed(_CONTAINER_INFO_PLIST),
                subprocess.TimeoutExpired(cmd="diskutil", timeout=30),
            ]
            result = create_volume("VOL", quota_gb=10, container="disk3")

        assert result.success is False


# ---------------------------------------------------------------------------
# delete_volume
# ---------------------------------------------------------------------------


class TestDeleteVolume:
    def test_happy_path(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = [
                _completed(_VOLUME_INFO_PLIST),           # diskutil info MYVOLUME
                _completed("Volume deleted successfully"),  # deleteVolume
            ]
            result = delete_volume("MYVOLUME")

        assert result.success is True
        assert "MYVOLUME" in result.message
        delete_call = mock_run.call_args_list[1][0][0]
        assert delete_call == ["diskutil", "apfs", "deleteVolume", "MYVOLUME"]

    def test_volume_not_found(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed("", returncode=1)
            result = delete_volume("GHOST")

        assert result.success is False
        assert "GHOST" in result.message
        # deleteVolume should never be called
        assert mock_run.call_count == 1

    def test_empty_name(self) -> None:
        result = delete_volume("")
        assert result.success is False

    def test_diskutil_delete_nonzero(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = [
                _completed(_VOLUME_INFO_PLIST),
                _completed("", stderr="volume is in use", returncode=1),
            ]
            result = delete_volume("MYVOLUME")

        assert result.success is False
        assert "volume is in use" in result.message

    def test_diskutil_raises(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = [
                _completed(_VOLUME_INFO_PLIST),
                OSError("permission denied"),
            ]
            result = delete_volume("MYVOLUME")

        assert result.success is False
        assert "permission denied" in result.message


# ---------------------------------------------------------------------------
# rename_volume
# ---------------------------------------------------------------------------


class TestRenameVolume:
    def test_happy_path(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed("Volume renamed\n")
            result = rename_volume("OLDNAME", "NEWNAME")

        assert result.success is True
        assert mock_run.call_count == 1
        assert mock_run.call_args[0][0] == ["diskutil", "rename", "OLDNAME", "NEWNAME"]

    def test_empty_old_name(self) -> None:
        result = rename_volume("", "NEWNAME")
        assert result.success is False
        assert "old_name" in result.message.lower()

    def test_empty_new_name(self) -> None:
        result = rename_volume("OLDNAME", "")
        assert result.success is False
        assert "new_name" in result.message.lower()

    def test_whitespace_new_name(self) -> None:
        result = rename_volume("OLDNAME", "   ")
        assert result.success is False

    def test_diskutil_nonzero(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(
                "", stderr="No volume named OLDNAME", returncode=1
            )
            result = rename_volume("OLDNAME", "NEWNAME")

        assert result.success is False
        assert "No volume named OLDNAME" in result.message

    def test_diskutil_raises(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = FileNotFoundError("diskutil missing")
            result = rename_volume("A", "B")

        assert result.success is False


# ---------------------------------------------------------------------------
# set_quota
# ---------------------------------------------------------------------------


class TestSetQuota:
    def test_happy_path(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed("Quota updated\n")
            result = set_quota("MYVOLUME", quota_gb=100)

        assert result.success is True
        call_args: list[str] = mock_run.call_args[0][0]
        assert call_args[:4] == ["diskutil", "apfs", "resizeContainer", "MYVOLUME"]
        assert "-quota" in call_args
        assert str(_gb_to_bytes(100)) in call_args

    def test_empty_name(self) -> None:
        result = set_quota("", quota_gb=10)
        assert result.success is False

    def test_zero_quota(self) -> None:
        result = set_quota("VOL", quota_gb=0)
        assert result.success is False

    def test_negative_quota(self) -> None:
        result = set_quota("VOL", quota_gb=-10)
        assert result.success is False

    def test_diskutil_nonzero(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(
                "", stderr="container too full", returncode=1
            )
            result = set_quota("VOL", quota_gb=500)

        assert result.success is False
        assert "container too full" in result.message

    def test_diskutil_raises(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = subprocess.TimeoutExpired(cmd="diskutil", timeout=30)
            result = set_quota("VOL", quota_gb=10)

        assert result.success is False


# ---------------------------------------------------------------------------
# list_snapshots
# ---------------------------------------------------------------------------


class TestListSnapshots:
    def test_happy_path(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(_SNAPSHOT_OUTPUT)
            result = list_snapshots("MYVOLUME")

        assert result.success is True
        snapshots = result.data["snapshots"]
        assert len(snapshots) == 2
        assert snapshots[0]["name"] == "com.apple.TimeMachine.2024-01-15-120000"
        assert snapshots[0]["date"] == "2024-01-15 12:00:00 +0000"
        assert mock_run.call_count == 1
        assert mock_run.call_args[0][0] == ["diskutil", "apfs", "listSnapshots", "MYVOLUME"]

    def test_no_snapshots(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed("No local snapshots found.\n")
            result = list_snapshots("MYVOLUME")

        assert result.success is True
        assert result.data["snapshots"] == []

    def test_empty_name(self) -> None:
        result = list_snapshots("")
        assert result.success is False

    def test_diskutil_nonzero(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(
                "", stderr="volume not found", returncode=1
            )
            result = list_snapshots("GHOST")

        assert result.success is False
        assert "volume not found" in result.message

    def test_diskutil_raises(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = OSError("I/O error")
            result = list_snapshots("MYVOLUME")

        assert result.success is False
        assert "I/O error" in result.message

    def test_raw_output_preserved(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(_SNAPSHOT_OUTPUT)
            result = list_snapshots("MYVOLUME")

        assert "raw" in result.data
        assert result.data["raw"] == _SNAPSHOT_OUTPUT


# ---------------------------------------------------------------------------
# take_snapshot
# ---------------------------------------------------------------------------


class TestTakeSnapshot:
    def test_happy_path(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            # diskutil info -plist for mount point resolution, then tmutil
            mock_run.side_effect = [
                _completed(_VOLUME_INFO_PLIST),             # diskutil info -plist
                _completed("Created snapshot\n"),            # tmutil localsnapshot
            ]
            result = take_snapshot("MYVOLUME")

        assert result.success is True
        tmutil_call: list[str] = mock_run.call_args_list[1][0][0]
        assert tmutil_call == ["tmutil", "localsnapshot", "/Volumes/MYVOLUME"]

    def test_volume_not_mounted(self) -> None:
        """diskutil returns a plist with no MountPoint → take_snapshot fails gracefully."""
        no_mount_plist = _plist_str(
            {"DeviceIdentifier": "disk3s5", "VolumeName": "MYVOLUME", "MountPoint": ""}
        )
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(no_mount_plist)
            result = take_snapshot("MYVOLUME")

        assert result.success is False
        assert "mount point" in result.message.lower()

    def test_diskutil_info_fails(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed("", returncode=1)
            result = take_snapshot("GHOST")

        assert result.success is False
        assert mock_run.call_count == 1  # tmutil never called

    def test_empty_name(self) -> None:
        result = take_snapshot("")
        assert result.success is False

    def test_tmutil_nonzero(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = [
                _completed(_VOLUME_INFO_PLIST),
                _completed("", stderr="snapshot failed", returncode=1),
            ]
            result = take_snapshot("MYVOLUME")

        assert result.success is False
        assert "snapshot failed" in result.message

    def test_tmutil_raises(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = [
                _completed(_VOLUME_INFO_PLIST),
                subprocess.TimeoutExpired(cmd="tmutil", timeout=30),
            ]
            result = take_snapshot("MYVOLUME")

        assert result.success is False

    def test_diskutil_info_raises(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = FileNotFoundError("diskutil not found")
            result = take_snapshot("MYVOLUME")

        assert result.success is False


# ---------------------------------------------------------------------------
# get_container_info
# ---------------------------------------------------------------------------


class TestGetContainerInfo:
    def test_happy_path(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(_APFS_LIST_PLIST)
            result = get_container_info()

        assert result.success is True
        containers = result.data["containers"]
        assert len(containers) == 1
        container = containers[0]
        assert container["device"] == "disk3"
        assert container["capacity_ceiling"] == 500_000_000_000
        assert container["capacity_free"] == 120_000_000_000
        assert len(container["volumes"]) == 1

        volume = container["volumes"][0]
        assert volume["name"] == "MYVOLUME"
        assert volume["device"] == "disk3s5"
        assert volume["mount_point"] == "/Volumes/MYVOLUME"

    def test_multiple_containers(self) -> None:
        plist_data = _plist_str(
            {
                "Containers": [
                    {
                        "ContainerReference": "disk3",
                        "Designation": "Physical",
                        "CapacityCeiling": 500_000_000_000,
                        "CapacityFree": 100_000_000_000,
                        "Volumes": [],
                    },
                    {
                        "ContainerReference": "disk4",
                        "Designation": "Physical",
                        "CapacityCeiling": 1_000_000_000_000,
                        "CapacityFree": 800_000_000_000,
                        "Volumes": [],
                    },
                ]
            }
        )
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(plist_data)
            result = get_container_info()

        assert result.success is True
        assert len(result.data["containers"]) == 2

    def test_empty_containers(self) -> None:
        plist_data = _plist_str({"Containers": []})
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(plist_data)
            result = get_container_info()

        assert result.success is True
        assert result.data["containers"] == []

    def test_diskutil_nonzero(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed("", returncode=1)
            result = get_container_info()

        assert result.success is False

    def test_diskutil_empty_output(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed("")
            result = get_container_info()

        assert result.success is False

    def test_bad_plist(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed("not a plist at all")
            result = get_container_info()

        assert result.success is False

    def test_diskutil_raises(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = FileNotFoundError("diskutil not found")
            result = get_container_info()

        assert result.success is False

    def test_correct_command_issued(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(_APFS_LIST_PLIST)
            get_container_info()

        assert mock_run.call_count == 1
        assert mock_run.call_args[0][0] == ["diskutil", "apfs", "list", "-plist"]


# ---------------------------------------------------------------------------
# get_volume_info
# ---------------------------------------------------------------------------


class TestGetVolumeInfo:
    def test_happy_path(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(_VOLUME_INFO_PLIST)
            result = get_volume_info("MYVOLUME")

        assert result.success is True
        data = result.data
        assert data["mount_point"] == "/Volumes/MYVOLUME"
        assert data["device"] == "disk3s5"
        assert data["size_bytes"] == 50_000_000_000
        assert data["free_bytes"] == 20_000_000_000
        assert data["volume_name"] == "MYVOLUME"
        assert data["file_system"] == "apfs"
        assert mock_run.call_count == 1
        assert mock_run.call_args[0][0] == ["diskutil", "info", "-plist", "MYVOLUME"]

    def test_fallback_size_key(self) -> None:
        """When TotalSize absent, Size key is used."""
        alt_plist = _plist_str(
            {
                "DeviceIdentifier": "disk3s5",
                "VolumeName": "VOL",
                "MountPoint": "/Volumes/VOL",
                "Size": 100_000_000_000,
                "FreeSpace": 50_000_000_000,
                "FilesystemType": "apfs",
            }
        )
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(alt_plist)
            result = get_volume_info("VOL")

        assert result.success is True
        assert result.data["size_bytes"] == 100_000_000_000

    def test_fallback_free_key(self) -> None:
        """When FreeSpace absent, APFSContainerFree is used."""
        alt_plist = _plist_str(
            {
                "DeviceIdentifier": "disk3s5",
                "VolumeName": "VOL",
                "MountPoint": "/Volumes/VOL",
                "TotalSize": 100_000_000_000,
                "APFSContainerFree": 40_000_000_000,
                "FilesystemType": "apfs",
            }
        )
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(alt_plist)
            result = get_volume_info("VOL")

        assert result.success is True
        assert result.data["free_bytes"] == 40_000_000_000

    def test_empty_name(self) -> None:
        result = get_volume_info("")
        assert result.success is False

    def test_whitespace_name(self) -> None:
        result = get_volume_info("   ")
        assert result.success is False

    def test_volume_not_found(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed(
                "", stderr="Could not find disk: GHOST", returncode=1
            )
            result = get_volume_info("GHOST")

        assert result.success is False
        assert "GHOST" in result.message

    def test_empty_stdout(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed("")
            result = get_volume_info("MYVOLUME")

        assert result.success is False

    def test_bad_plist(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.return_value = _completed("not a plist")
            result = get_volume_info("MYVOLUME")

        assert result.success is False

    def test_diskutil_raises(self) -> None:
        with patch("devdrive_v2.apfs_volume._run") as mock_run:
            mock_run.side_effect = subprocess.TimeoutExpired(cmd="diskutil", timeout=30)
            result = get_volume_info("MYVOLUME")

        assert result.success is False


# ---------------------------------------------------------------------------
# VolumeResult dataclass
# ---------------------------------------------------------------------------


class TestVolumeResult:
    def test_defaults(self) -> None:
        r = VolumeResult(success=True, message="ok")
        assert r.data == {}

    def test_with_data(self) -> None:
        r = VolumeResult(success=False, message="err", data={"code": 1})
        assert r.data["code"] == 1

    def test_data_not_shared_between_instances(self) -> None:
        """Each VolumeResult gets its own default dict (field(default_factory=dict))."""
        r1 = VolumeResult(success=True, message="a")
        r2 = VolumeResult(success=True, message="b")
        r1.data["x"] = 1
        assert "x" not in r2.data

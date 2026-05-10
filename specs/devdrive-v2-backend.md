# Spec: DevDrive v2 Backend — Native APFS Volumes

## Purpose
Replace the sparseimage-based v1 DevDrive backend with native APFS volumes. The reconcile loop becomes an XPC-callable service. The fleet registry schema is updated to v2.

## Key Differences from v1

| Concern | v1 (sparseimage) | v2 (APFS native) |
|---------|-----------------|-----------------|
| Volume backing | `.sparseimage` file on host disk | Native APFS volume on host container |
| Mount mechanism | `hdiutil attach` | Volume already visible when container mounts |
| Size limits | Fixed at image creation | Elastic (shares container free space) |
| Crash safety | Image can corrupt | APFS journaling |
| Migration required | N/A | Yes — from v1 registry |

---

## Fleet Registry v2 Schema

File: `~/DevDrive/fleet.json`

```json
{
  "version": "2.0",
  "volumes": [
    {
      "name": "DDRV901",
      "label": "901DEVLIB",
      "purpose": "Xcode DerivedData + CoreSimulator",
      "backend": "apfs-native",
      "container": "disk4",
      "host": "YJ_MORE",
      "mountPoint": "/Volumes/DDRV901",
      "symlinks": [
        { "source": "~/Developer", "target": "/Volumes/DDRV901/DerivedData" },
        { "source": "~/Library/Developer/CoreSimulator/Devices", "target": "/Volumes/DDRV901/CoreSimulator/Devices" }
      ],
      "status": "mounted",
      "lastSeenAt": "2026-05-09T20:00:00Z"
    }
  ],
  "schemaVersion": "2.0",
  "updatedAt": "2026-05-09T20:00:00Z"
}
```

### Field definitions
- `backend`: `"apfs-native"` (v2) or `"sparseimage"` (v1 legacy, read-only during migration)
- `container`: disk identifier hosting the APFS volume (e.g., `disk4` = YJ_MORE partition)
- `host`: external volume name; daemon watches `/Volumes/<host>` for connect events
- `symlinks`: array of `{ source, target }` pairs managed by reconcile loop
- `status`: `mounted | unmounted | error | migrating`

---

## Reconcile Loop as XPC Service

### Trigger modes
1. **Daemon-internal**: fired on host-volume connect event
2. **XPC-callable**: `LFGDaemonProtocol.reconcile(reply:)` from LFGApp or CLI
3. **LaunchAgent schedule**: every 15 minutes via `StartInterval` in plist

### Reconcile steps (idempotent)
1. Load `fleet.json` v2
2. For each volume: verify mount point exists; if not and host is present, re-attach (APFS: `diskutil mount <label>`)
3. For each symlink in volume record: verify source → target is valid; repair if dangling or missing
4. Skip symlinks whose source is a home-dir offload (flag: `"offload": true`) — do not redirect to internal fallback
5. Write updated `status` and `lastSeenAt` back to fleet.json
6. Emit XPC reply with `ReconcileResult` (volumes checked, repaired, failed)
7. POST to APM bridge: `http://localhost:3032/api/notify`

---

## Migration: v1 → v2

### Tool: `devdrive/migrate_v1.py` (existing file, extend)

#### Migration steps
1. Read existing `fleet.json` (detect `version` field; if absent, treat as v1)
2. For each sparseimage entry:
   a. Ensure sparseimage is attached (hdiutil attach)
   b. `rsync -a` contents to new APFS volume on same host container
   c. Verify checksums (sha256 spot-check of 100 random files)
   d. Update fleet.json entry: set `backend: "apfs-native"`, remove `imagePath`
   e. Write `fleet.json` with `version: "2.0"`
3. On full success: detach and archive old sparseimage to `~/.config/lfg/archive/`
4. Dry-run mode: print plan without executing

### Safety
- Never delete sparseimage until migration verified
- Full rollback if any rsync step fails (revert fleet.json entry)
- Migration log at `~/.config/lfg/migrate-v1-v2.log`

---

## TDD Requirements

### Mock strategy
`MockDiskutil`: captures `diskutil mount/unmount/list` invocations and returns configurable stdout fixtures. Never invokes real `diskutil` in tests.

### Test cases (Tests/LFGKitTests/)
- `FleetRegistryV2Tests`
  - Parse v2 fleet.json; assert all fields populated
  - Parse v1 fleet.json (no version field); assert migration-needed flag set
  - Round-trip: load → mutate status → save → reload; assert idempotent
- `ReconcileLoopTests`
  - All mounts healthy: verify no repair actions emitted
  - One symlink dangling: verify single repair action with correct source/target
  - Home-dir offload symlink dangling: verify NOT redirected to internal fallback
  - Host volume absent: verify volumes skipped gracefully, status set to `unmounted`
- `MigrationTests`
  - Dry-run: verify plan output contains expected rsync commands, no filesystem changes
  - Single-volume migration: rsync to temp dir, verify fleet.json updated correctly
  - Rollback: inject rsync failure; verify fleet.json unchanged

### Coverage target
80% line coverage on reconcile loop and fleet registry types.

## Acceptance Criteria
- `lfg devdrive reconcile` with v2 fleet.json completes in under 5 seconds for a 5-volume fleet
- Migration dry-run produces human-readable plan with no side effects
- Reconcile correctly skips home-dir offload symlinks (regression: CP-108)
- All ReconcileLoopTests pass with MockDiskutil (zero real diskutil calls in test suite)

# LFG — Local File Guardian
**Project**: LFG macOS disk management suite
**Formation**: fmt-lfg-fleet-20260419
**Plane Project ID**: `6bc05edb-a2b4-44c1-9cfc-2c938edb38a3` (prefix: LFG)
**Checkpoint Range**: CP-84..CP-100

---

## Project Overview

LFG is a macOS disk management suite built in Bash, Swift, Python3, and HTML/CSS/JS. It provides 9 specialized modules accessed via a central dispatcher, a native Swift AppKit viewer (`LFG.app`), a menubar helper, and a CCEM APM integration bridge.

**Dispatcher**: `~/tools/@yj/lfg/lfg`
**Viewer**: `~/tools/@yj/lfg/.build/release/LFG` (Swift AppKit, HTTP server on port 8080)

---

## Module Inventory

| Module | File | Purpose |
|--------|------|---------|
| WTFS | `lib/scan.sh` | Disk usage analysis (tree + pie chart) |
| DTF | `lib/clean.sh` | Cache discovery and cleanup |
| BTAU | `lib/btau.sh` | Sparse image backup lifecycle |
| DEVDRIVE | `lib/devdrive.sh` | Native APFS volume + reconcile loop |
| SSD | `lib/ssd.sh` | Spotlight index manager |
| STFU | `lib/stfu.sh` | Process noise suppressor |
| AI | `lib/ai.sh` | AI-assisted recommendations |
| CHAT | `lib/chat.sh` | In-tool conversation interface |
| DASHBOARD | `lib/dashboard.sh` | Unified status dashboard |

---

## DevDrive Architecture

**Purpose**: Use available EXTERNAL volume space via dedicated directories combined via symlink amalgamation in sparseimages. The `~/DevDrive` directory should contain symlinks pointing to sparseimage-backed APFS volumes hosted on external drives.

**External volume**: `/Volumes/YJ_MORE` (128GB, ~118GB free) — the intended host for all sparseimages.

**Key paths**:
- `~/DevDrive/` — symlink forest (sparseimage mount points)
- `~/DevDrive/fleet.json` — volume registry (v1.3 post-remediation)
- `~/.config/lfg/state.json` — live runtime state
- `~/tools/@yj/lfg/lib/devdrive.sh` — 1,040-line module with inline Python3

**Active APFS volumes** (900-series):
| Volume | Purpose | Host (post-remediation) |
|--------|---------|------------------------|
| 900HOOKS | Claude Code hooks storage | Internal |
| 901DEVLIB | Xcode DerivedData + CoreSimulator | YJ_MORE |
| 902APMDR | CCEM APM data | Internal |
| 903LUME | ~/.claude/projects + tasks | Internal |
| 904MEMVT | Memory vault (fsck recovery) | YJ_MORE |

**Key symlinks managed by DDRV901**:
- `~/Developer` → `/Volumes/DDRV901/DerivedData`
- `~/Library/Developer/CoreSimulator/Devices` → `/Volumes/DDRV901/CoreSimulator/Devices`

---

## DevDrive v3 Runbook

DevDrive v3 uses a three-tier model: **SourceVolume** (physical host) → **VolumeBackend** (sparseimage) → **OffloadRule** (symlink). All configuration lives in `~/DevDrive/fleet.json`.

### Adding a new SourceVolume

Edit the `external_hosts[]` array in `~/DevDrive/fleet.json`:

```json
{
  "name": "MY_DRIVE",
  "mount": "/Volumes/MY_DRIVE",
  "role": "external_host",
  "available_gb": 256,
  "status": "active",
  "keep_awake": true
}
```

`FleetRegistry` picks it up automatically on next load. Set `keep_awake: true` to prevent the drive from spinning down during long builds.

### Adding a new VolumeBackend

Edit the `drives[]` array in `~/DevDrive/fleet.json`. Set `reconnect_policy` to `"auto"` for the app to attach the sparseimage automatically when its host mounts:

```json
{
  "id": "905MYDATA",
  "image": "/Volumes/MY_DRIVE/DevDrive/905MYDATA.dmg.sparseimage",
  "mount": "/Volumes/DDRV-905-MYDATA",
  "host": "MY_DRIVE",
  "tier": "cold",
  "purpose": "Description of contents",
  "reconnect_policy": "auto",
  "symlinks": []
}
```

Only backends whose `host` matches a `SourceVolume.name` and whose `reconnect_policy` is `"auto"` are auto-attached at mount time (`FleetRegistry.autoBackends(forHost:)`).

### Adding an OffloadRule

Add entries to `drives[].symlinks[]` using the arrow format. The left side is the home-directory path to replace with a symlink; the right side is the absolute target on the APFS volume:

```json
"symlinks": [
  "~/.my-tool-cache → /Volumes/DDRV-905-MYDATA/my-tool-cache"
]
```

The separator is a Unicode RIGHT ARROW (U+2192) surrounded by spaces. `OffloadRule.isHealthy` returns `true` when the symlink at the resolved source path already points to the declared target.

### NSWorkspace auto-mount flow

When YJ_MORE (or any known host) connects:

1. macOS fires `NSWorkspace.didMountNotification`.
2. `AppState.setupMountWatcher()` receives the notification; it checks `registry.isKnownHost(volumeName)` and discards unknown volumes.
3. `MountOrchestrator.attachAll(forHost: volumeName)` is called; it iterates `registry.autoBackends(forHost:)` and runs `hdiutil attach` for each unmounted sparseimage.
4. `AppState.handleAttachResults(_:host:)` fires a `UNUserNotificationCenter` notification summarising how many volumes attached and which (if any) failed.

`setupMountWatcher()` is idempotent — calling it multiple times is safe because it returns early if `orchestrator != nil`.

### Running the test suite

```bash
swift test
```

Run from the package root `~/tools/@yj/lfg/`. The suite currently contains 126 tests across 5 v3 test files plus all prior tests. Expected result: 0 failures.

### Key file locations — v3 models and views

| Path | Contents |
|------|----------|
| `Sources/LFGKit/SourceVolume.swift` | `SourceVolume` struct — maps `external_hosts[]` |
| `Sources/LFGKit/VolumeBackend.swift` | `VolumeBackend` struct — maps `drives[]`, exposes `offloadRules`, `isAutoReconnect`, `resolvedImagePath` |
| `Sources/LFGKit/OffloadRule.swift` | `OffloadRule` struct — parses arrow strings, exposes `resolvedSource`, `isHealthy` |
| `Sources/LFGKit/FleetRegistry.swift` | v2 + v3 parallel APIs; v3 adds `allSourceVolumes`, `allVolumeBackends`, `volumeBackends(forHost:)`, `sourceVolume(named:)`, `autoBackends(forHost:)` |
| `Sources/LFGApp/AppState.swift` | `setupMountWatcher()`, `handleAttachResults(_:host:)`, `sendNotification(title:body:identifier:)` |
| `Sources/LFGApp/Views/DevDrive/DevDriveView.swift` | Root CloudMounter-inspired three-tier view |
| `Sources/LFGApp/Views/DevDrive/SourceVolumeSection.swift` | Collapsible section per SourceVolume |
| `Sources/LFGApp/Views/DevDrive/VolumeBackendCard.swift` | Capacity bar + 4-state status dot per VolumeBackend |
| `Sources/LFGApp/Views/DevDrive/OffloadRuleRow.swift` | Health indicator + Restore button per OffloadRule |
| `Sources/LFGApp/Views/DevDrive/VolumeStatusDot.swift` | Shared 4-state status dot component |
| `Tests/LFGKitTests/` | SourceVolumeTests, OffloadRuleTests, VolumeBackendTests, FleetRegistryV3Tests, MountOrchestratorV3Tests |

---

## Key Files

| Path | Purpose |
|------|---------|
| `~/tools/@yj/lfg/lfg` | Main dispatcher |
| `~/tools/@yj/lfg/lib/devdrive.sh` | DevDrive module (1,040 lines, Python3 embedded) |
| `~/tools/@yj/lfg/devdrive/observers.py` | Pressure observers (4 watchers) |
| `~/tools/@yj/lfg/devdrive/reconcile.py` | Reconcile loop + drift classifier |
| `~/tools/@yj/lfg/devdrive/actions.py` | Idempotent repair actions |
| `~/tools/@yj/lfg/devdrive/apfs_volume.py` | APFS volume management |
| `~/tools/@yj/lfg/devdrive/migrate_v1.py` | sparseimage → APFS migration |
| `~/DevDrive/fleet.json` | Volume registry |
| `~/.config/lfg/state.json` | Runtime state |
| `~/Library/LaunchAgents/io.lfg.devdrive-reconcile.plist` | Reconcile LaunchAgent |

---

## CCEM APM Integration

**Bridge**: `~/Developer/ccem/apm/bridges/lfg-devdrive.json`
**Dashboard**: `http://localhost:3032/showcase?project=lfg`
**Showcase**: `http://localhost:8080/lfg.html` (LFG.app HTTP server)
**APM notify**: `POST http://localhost:3032/api/notify`

---

## Fleet Formation

**Formation ID**: `fmt-lfg-fleet-20260419`
**PRD**: `~/tools/@yj/lfg/.claude/ralph/prd.json`
**17 stories**: US-A-001..007 (showcase-v2) + US-B-001..010 (devdrive-remediation)

Squadron Alpha (showcase-v2): LFG-42..LFG-48
Squadron Bravo (devdrive-remediation): LFG-49..LFG-58

---

## Implementation Checkpoints — DevDrive Offload & Storage Recovery (2026-05-01)

### Phase: Internal Storage Crisis Recovery + Auto-Mount Hardening

- [x] **CP-100**: Emergency disk recovery — emptied Trash, compacted 902APMDR, cleared ShipIt/aikido caches (+4GB freed)
- [x] **CP-100a**: Remounted YJ_MORE sparseimages (901/904/900HOOKS were ghosted), rebuilt symlink forest in ~/DevDrive
- [x] **CP-100b**: Rewrote devdrive-automount.sh as fleet.json-aware helper; added WatchPaths for external hosts to plist; reloaded both LaunchAgents
- [x] **CP-100c**: Offloaded .npm-cache (4.4GB), .vscode (3.3GB), .asdf (6.5GB), .lmstudio (1.4GB), .continue (1.3GB), .azurelogicapps (2.4GB) → DDRV-901-DEVLIB; created symlinks; freed 19GB from internal
- [x] **CP-100d**: Updated fleet.json v1.9 — fixed 902APMDR mount path, added all 6 home-dir symlinks to 901DEVLIB record
- [x] **CP-103**: Verify fleet.json v1.9 symlinks completeness — confirmed this session (US-DVO-003) (LFG-62)
- [x] **CP-108**: Reconcile agent: skip fallback redirect for home-dir offload symlinks — patched devdrive-reconcile.sh (US-DVO-008)
- [x] **CP-101**: WTFS offload-audit command — ranked internal vs DevDrive candidates report (US-DVO-001) (LFG-60) — 5d4c849
- [x] **CP-102**: Expand DDRV-901 sparseimage to 80GB (US-DVO-002) (LFG-61) — done prior session
- [x] **CP-104**: devdrive-automount sync-plist: auto-generate WatchPaths from fleet.json (US-DVO-004) (LFG-63) — 13629ca
- [x] **CP-105**: DTF downloads-audit scan rule for files >90 days (US-DVO-005) (LFG-64) — 475b585
- [x] **CP-106**: fleet.json known_internal_consumers metadata for iCloud dirs (US-DVO-006) (LFG-65) — 68f9013
- [x] **CP-107**: YJ_MORE drive stability — investigate disconnect root cause, add keep_awake support (US-DVO-007) — c2b0a29

---

## Implementation Checkpoints — DevDrive v3 Redesign (2026-05-21)

### Sprint: DevDrive v3 — Native Architecture + CloudMounter UX

#### Wave 1 — Foundation + Critical Bugfixes (Done)
- [x] **CP-109**: Fleet schema v3 + Swift model redesign (SourceVolume, OffloadRule, VolumeBackend, updated FleetRegistry)
- [x] **CP-110**: Fix MenuBarExtra notifications — UNUserNotificationCenter integration
- [x] **CP-111**: Wire NSWorkspace.didMountNotification → immediate symlink restore (Option 3 drift fix)

#### Wave 2 — UI Redesign + TDD (Todo)
- [x] **CP-112**: CloudMounter-inspired DevDriveView redesign — three-tier Source/Volume/Rules
- [x] **CP-113**: Volume cards: inline capacity bar + four-state status dots (none/green/orange/red)
- [x] **CP-114**: MenuBar redesign — source groups, filter input, drift alerts
- [x] **CP-115**: OffloadRule model + UI — symlink health display per volume
- [x] **CP-116**: TDD unit + integration tests for v3 models and mount wiring

#### Wave 3 — Documentation (Done)
- [x] **CP-117**: opsdoc + docsmax + coalesce — full LFG documentation refresh

#### Backlog
- [ ] **CP-118**: [Backlog] Full Swift reconcile — replace Python daemon with native LFGKit implementation

---

## Implementation Checkpoints — DevDrive v3 UI Expansion (2026-05-24)

### Sprint: DevDrive v3 UI — 10-iteration multi-view + admin suite (fmt-lfg-ddrv3-ui-20260524)

- [x] **v3.1 (W1A1)**: DevDriveViewMode enum + `@AppStorage` persisted mode switcher toolbar (list/card/graph)
- [x] **v3.2 (W1A2)**: VolumeCardGridView — `LazyVGrid` card layout with capacity rings and `VolumeDetailSheet`
- [x] **v3.3 (W2A1)**: VolumeGraphView — Canvas-based hierarchical node graph (SourceVolume→VolumeBackend→OffloadRule)
- [x] **v3.4 (W2A2)**: Source Volumes Admin — `DiskScanner` (FileManager API), `SourceVolumesAdminView`, `AddSourceVolumeSheet`
- [x] **v3.5 (W3A1)**: Drive Relocation Wizard — `RelocationCoordinator` actor + `DriveRelocationSheet` (4-step wizard)
- [x] **v3.6 (W3A2)**: Volume Settings Panel — `FleetEditor` atomic JSON mutator + `VolumeSettingsSheet` (purpose/tier/policy/symlinks)
- [x] **v3.7 (W4A1)**: OffloadRule Manager — `OffloadRuleManagerSheet` with per-rule health, Restore, Add, Remove actions
- [x] **v3.8 (W4A2)**: Capacity Dashboard — `CapacityDashboardView` (stacked bars, summary cards, rebalance suggestions)
- [x] **v3.9 (W5A1)**: Admin Preferences — `DevDriveSettingsView` tab in Settings scene (fleet path, auto-mount, daemon, keep-awake)
- [x] **v3.10 (W5A2)**: TDD — 149 tests passing (DiskScannerTests 10, FleetEditorTests 11, RelocationCoordinatorTests 6); release build v3.1.0

---

## Stack

- **Bash** 5+ (modules, dispatcher)
- **Swift** 5.9+ (AppKit viewer `LFG.app`, menubar helper)
- **Python3** (DevDrive engine, embedded in devdrive.sh and standalone in devdrive/)
- **HTML/CSS/JS** (showcase client, Tailwind CDN)
- **Elixir/Phoenix** (CCEM APM, external dependency)

---

## Attribution Policy

Never include "Generated with Claude Code", "Co-Authored-By: Claude", or any AI attribution in commits, PRs, or issues for this project.

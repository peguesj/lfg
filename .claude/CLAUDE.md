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
- [ ] **CP-101**: WTFS offload-audit command — ranked internal vs DevDrive candidates report (US-DVO-001) (LFG-60)
- [ ] **CP-102**: Expand DDRV-901 sparseimage to 80GB (US-DVO-002) (LFG-61)
- [ ] **CP-104**: devdrive-automount sync-plist: auto-generate WatchPaths from fleet.json (US-DVO-004) (LFG-63)
- [x] **CP-105**: DTF downloads-audit scan rule for files >90 days (US-DVO-005) (LFG-64) — 475b585
- [x] **CP-106**: fleet.json known_internal_consumers metadata for iCloud dirs (US-DVO-006) (LFG-65) — 68f9013
- [x] **CP-107**: YJ_MORE drive stability — investigate disconnect root cause, add keep_awake support (US-DVO-007) — c2b0a29

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

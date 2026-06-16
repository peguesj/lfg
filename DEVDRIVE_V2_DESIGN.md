# LFG DevDrive v2 — Self-Correcting Architecture Design

> **Status**: Design draft
> **Author**: Investigation conducted 2026-04-11 during claude-expertise disk-space incident
> **Supersedes**: Sparseimage-based devdrive (current `lib/devdrive.sh` + `btau.core.sparse`)
> **Scope**: Replace crude sparseimage backend with kernel-integrated storage + add a reconcile loop that actively heals drift

---

## 1. Problem Statement

DevDrive v1 works as a convenience layer, but during the 2026-04-11 investigation we hit several real failure modes that the current module cannot self-correct. On top of that, the user reports a recurring pattern:

> "Sometimes when I restart I suddenly have over 50 GB storage and then it quickly dwindles down, then up and down about 20 ± 10 GB at quick intervals while I am developing."

This fluctuation is **not caused** by devdrive directly, but devdrive is in the best position to observe and manage it because it already tracks disk state and mounts.

### 1.1 Observed failure modes (forensic)

| # | Symptom | Root cause | Self-correctable? |
|---|---------|------------|---|
| 1 | Homebrew cache directory existed where a symlink should be (52 MB) | Manual `brew` install after devdrive config resurrected the real dir | **Yes** — detect with `devdrive_forest.json` reconcile |
| 2 | Xcode DerivedData symlink missing entirely, 128 MB on DDRV901 orphaned | Xcode overwrote the symlink on first launch after upgrade | **Yes** — same reconcile pass |
| 3 | `ExpertiseApp/.build` / `expertise_api/_build` / `deps` grew to ~370 MB on root disk | No devdrive rule existed for this project yet | **Partial** — needs auto-adoption rule ("any dir named `.build`, `_build`, `deps`, `node_modules` in a protected project → relocate") |
| 4 | Sparsebundle band files grow monotonically (903LUME 1.2 GB / 165 bands, 920COWORK 1.5 GB / 207 bands) | `hdiutil compact` is never run; bands do not shrink when files inside are deleted | **Yes** — periodic compaction when image is idle |
| 5 | Docker.raw shrank only 700 MB after a 3.3 GB internal prune | sparse-file TRIM/discard is only honored on clean Docker Desktop shutdown | **Yes** — observe + restart docker on pressure |
| 6 | Disk showed 3.2 GB free → 317 MiB free in ~60 seconds during build | clang cache + swift module cache + xcode indexing + snapshot creation racing each other | **Yes** — active pressure monitor can evict in order of priority |
| 7 | 50 GB fresh after restart → 20 GB during dev → bounces | APFS is reclaiming purgeable space / snapshots under pressure; creation + eviction race is visible as fluctuation | **Yes** — this is exactly what a self-correcting loop is for |

### 1.2 The fluctuation, explained

macOS APFS reports two distinct numbers for "free space":

```
df /                 -> "visible" free space (what apps see)
diskutil info /      -> "Container Free Space" (includes purgeable)
                     -> "Purgeable Space" (snapshots, caches, CoW)
```

The gap between the two is the **purgeable pool**: APFS local Time Machine snapshots, caches marked `com.apple.metadata:_kMDItemVolumePurgeable`, CoW clone dedup savings, Xcode cached archives, Docker.raw unreclaimed blocks, clang module cache, swap.

During a clean boot:
1. `~/Library/Developer/CoreSimulator/Caches` is fresh → 3-5 GB headroom
2. clang module cache under `/var/folders/.../C/clang` is empty → 500 MB headroom
3. Xcode DerivedData is purged on upgrade → 2-5 GB headroom
4. APFS snapshots are young, none pinned → 10-30 GB purgeable pool
5. Swap file collapsed → 2 GB
6. **Total apparent free**: ~50 GB

During active dev:
1. Swift/clang compiles → module cache balloons (-500 MB to -2 GB per session)
2. Xcode indexing → DerivedData.noindex grows (-1 to -4 GB per project)
3. Docker builds → VM raw file extends (-500 MB to -3 GB)
4. Simulator boots → runtime snapshot extends (-500 MB)
5. APFS snapshot fires every hour → -200 to -1500 MB per snapshot
6. Pressure trigger hits → APFS purges oldest purgeable space → +2 to +10 GB

**Result**: rapid sawtooth between 20 GB and 40 GB, stabilizing around 20 GB under sustained work. Exactly what you see.

### 1.3 Current architecture: the sparseimage problem

The current stack is:

```
                   [ symlink forest in /Volumes/900DEVELOPER/ ]
                                      |
                          hdiutil attach (kernel-level)
                                      |
     [ DDRV900.sparseimage | DDRV901.sparseimage | 903LUME.sparsebundle | ... ]
                                      |
                        stored as files on Macintosh HD
                                      |
                            [ APFS root volume ]
```

**Every byte "moved to devdrive" is still on the root disk**, wrapped in a sparse-file abstraction that:
- Grows monotonically (no auto-compact)
- Accounts for free space inside the image *separately* from the host, hiding real pressure
- Consumes an extra `hdiutil` process per mount
- Requires custom LaunchAgent (`io.lfg.devdrive-automount.plist`) to survive reboot
- Loses its mount cleanly on battery / sleep edge cases

The sparseimage approach was originally justified because it let each "drive" have a separate volume name — but **APFS containers already do that natively**, for free, with no overhead.

---

## 2. Proposed Architecture: DevDrive v2

### 2.1 New backend: native APFS volumes in the root container

Replace every `*.sparseimage` / `*.sparsebundle` with an APFS volume created directly in the root container:

```bash
diskutil apfs addVolume disk3 APFS DDRV900 -quota 40g -role U
diskutil apfs addVolume disk3 APFS DDRV901 -quota 60g -role U
diskutil apfs addVolume disk3 APFS DDRV903 -quota 80g -role U
```

**Characteristics:**

| Property | Sparseimage v1 | APFS Volume v2 |
|---|---|---|
| Kernel integration | via hdiutil loopback | **native** |
| Free space accounting | separate pool, stale | **shared with container** |
| Write overhead | host file grows + discard dance | **zero** — direct APFS write |
| Reclamation on delete | manual `hdiutil compact` | **automatic** — CoW + TRIM |
| Survives reboot | LaunchAgent re-attach | **automatic** — mounted by APFS at boot |
| Quota / reserve | none | **native** (`-quota`, `-reserve`) |
| Snapshots | none | **native APFS snapshots** |
| Encryption | sparseimage-level only | **FileVault volume-level** |
| Finder sidebar | same | same |
| Mount point path | `/Volumes/DDRV900` | `/Volumes/DDRV900` (identical) |
| Removable | `hdiutil detach` + delete file | `diskutil apfs deleteVolume` (instant) |

The migration is **transparent** to every consumer — mount points stay at `/Volumes/DDRV<N>` so the existing symlink forest keeps working.

### 2.2 Alternatives considered and rejected

| Alternative | Verdict | Why |
|---|---|---|
| **macFUSE** (classic) | Rejected | Requires kext, deprecated on Apple Silicon, needs SIP concessions |
| **fuse-t** (NFS-backed FUSE) | Rejected for this use case | Great for cloud/overlay mounts; adds NFS stack overhead for a purely local dev-artifact store |
| **ZFS on macOS (OpenZFS)** | Reject for v2, reconsider for v3 | Gives true self-healing (scrubs, CoW, native snapshots) but adds kext-equivalent dependency and user-space ZFS CLI fluency requirement |
| **NBD / iSCSI on localhost** | Rejected | Adds network stack for local files |
| **DiskImageMounter framework (macOS 13+)** | Rejected | Wraps `hdiutil` under the hood; no net improvement |
| **Firmlinks** | N/A | Not user-configurable (fixed list in `/usr/share/firmlinks`) |
| **APFS volumes in root container** | **SELECTED** | Native, zero-overhead, shared free pool, native snapshots, survives reboot, no extra daemons |

Key insight: **`.sparseimage` on an APFS host disk is strictly worse than an APFS volume.** The sparseimage was only valuable when the host filesystem was HFS+, which pre-dates this machine.

### 2.3 Self-correcting reconcile loop

A new module `btau/core/reconcile.py` runs every 5 minutes (via LaunchAgent) and performs a closed-loop health check:

```
┌─────────────────────────────────────────────────────┐
│                 RECONCILE CYCLE                      │
│                                                      │
│  1. Observe                                          │
│     - df /, diskutil info /, tmutil listlocalsnaps  │
│     - for each DDRV volume: mounted? free? quota?   │
│     - for each forest entry: exists? symlink?       │
│                                                      │
│  2. Classify drift                                   │
│     - MISSING_LINK: expected symlink not present    │
│     - STALE_TARGET: symlink -> dead path            │
│     - REAL_DIR_DRIFT: real dir where symlink should │
│     - UNMOUNTED_VOL: volume expected but not up     │
│     - OVERSIZED: real dir matches auto-adopt rule   │
│     - BAND_BLOAT: sparseimage grown > N GB idle     │
│     - SNAPSHOT_LOCKED: purgeable > 5 GB, df < 2 GB  │
│     - SWAP_PRESSURE: swap > 4 GB                    │
│                                                      │
│  3. Act (with dry-run guard)                         │
│     MISSING_LINK      -> recreate from forest config │
│     STALE_TARGET      -> attempt remount then relink │
│     REAL_DIR_DRIFT    -> rsync to vol, verify, swap │
│     UNMOUNTED_VOL     -> diskutil mount              │
│     OVERSIZED         -> propose relocation (APM)   │
│     BAND_BLOAT        -> detach + hdiutil compact   │
│     SNAPSHOT_LOCKED   -> tmutil thinlocalsnapshots  │
│     SWAP_PRESSURE     -> sudo dynamic_pager restart │
│                                                      │
│  4. Record                                           │
│     - ~/.config/lfg/reconcile_log.jsonl             │
│     - APM notification for each non-trivial action  │
│     - Update forest state with observed values      │
└─────────────────────────────────────────────────────┘
```

**Key invariants:**
- Every action is idempotent.
- Every action has a dry-run mode that is the default on first install.
- Every action emits before/after metrics to APM.
- Auto-rsync (REAL_DIR_DRIFT) never fires without checksum verification.
- Compaction (BAND_BLOAT) only fires when the image is not mounted AND has been idle > 15 min.

### 2.4 New state model

`~/.config/lfg/devdrive_state.json`:

```json
{
  "version": "2.0",
  "updated_at": "2026-04-11T12:00:00Z",
  "backend": "apfs_volume",
  "root_container": "disk3",
  "volumes": [
    {
      "name": "DDRV903",
      "mount_point": "/Volumes/DDRV903",
      "device": "disk24s1",
      "quota_bytes": 85899345920,
      "used_bytes": 1073741824,
      "free_bytes": 84825604096,
      "role": "user",
      "migrated_from": {
        "type": "sparsebundle",
        "path": "/Users/jeremiah/.config/btau/903LUME.sparsebundle",
        "host_bytes_recovered": 1288490188
      },
      "health": "ok",
      "last_reconcile": "2026-04-11T11:55:00Z"
    }
  ],
  "forest": [
    {
      "id": "homebrew-cache",
      "system_path": "~/Library/Caches/Homebrew",
      "volume": "DDRV902",
      "target": "/Volumes/DDRV902/caches/homebrew",
      "expected_kind": "symlink",
      "last_observed_kind": "symlink",
      "last_drift_at": "2026-04-11T05:35:00Z",
      "drift_count": 1,
      "auto_repair": true,
      "size_hint_mb": 52
    }
  ],
  "metrics": {
    "root_free_gb_history": [
      {"ts": "2026-04-11T12:00:00Z", "df_free_gb": 1.0, "container_free_gb": 5.1, "purgeable_gb": 4.1},
      {"ts": "2026-04-11T12:05:00Z", "df_free_gb": 1.3, "container_free_gb": 5.1, "purgeable_gb": 3.8}
    ],
    "pressure_events": [
      {"ts": "2026-04-11T05:37:00Z", "trigger": "df_free_lt_1gb", "action": "tmutil_thin", "recovered_gb": 2.1}
    ]
  }
}
```

The `metrics.root_free_gb_history` ring buffer (last 288 samples = 24h at 5-min resolution) is what answers the user's "why does it go up and down" question — the loop can show a graph.

### 2.5 New CLI surface

```
lfg devdrive doctor             # Full health report: forest + volumes + pressure + history
lfg devdrive reconcile          # Run one reconcile cycle now (dry-run by default)
lfg devdrive reconcile --apply  # Run with real repairs
lfg devdrive reconcile --watch  # Start foreground loop (Ctrl-C to stop)
lfg devdrive adopt <path>       # Add a new path to the forest + auto-relocate
lfg devdrive migrate v1-to-v2   # Walk sparseimage -> APFS volume migration
lfg devdrive compact <vol>      # Force one-shot compaction (v1 legacy)
lfg devdrive pressure           # Show purgeable / snapshot / swap breakdown
lfg devdrive history            # Time-series of df_free_gb over last 24h
```

### 2.6 Migration plan: v1 → v2

1. **Preflight**
   - Root container must have `quota_sum + current_used < container_capacity`
   - All v1 sparseimages must currently be attached (we migrate live)
   - Write a pre-migration manifest checksum for each v1 volume

2. **Per volume** (one at a time, smallest first to validate):
   - `diskutil apfs addVolume disk3 APFS ${NAME}-v2 -quota ${Q}`
   - `rsync -aHAX --info=progress2 /Volumes/${NAME}/ /Volumes/${NAME}-v2/`
   - `diff -rq /Volumes/${NAME} /Volumes/${NAME}-v2` (or `shasum` sample)
   - `hdiutil detach /Volumes/${NAME}`
   - `diskutil rename /Volumes/${NAME}-v2 ${NAME}`
   - Delete sparseimage file only after 24 h grace period
   - Reload forest symlinks (they don't change — mount point is identical)

3. **Rollback strategy**
   - Keep v1 sparseimage files for 24 h minimum
   - If any forest reconcile fails after migration, `hdiutil attach` the old image to a shadow mount (`/Volumes/${NAME}-v1-rollback/`) and re-rsync
   - A rollback takes ~5 min per volume

4. **Post-migration cleanup**
   - Delete sparseimage files
   - Remove `io.lfg.devdrive-automount.plist` (no longer needed; APFS auto-mounts)
   - Install `io.lfg.devdrive-reconcile.plist` (new reconcile LaunchAgent)

### 2.7 Addressing the 50 GB → 20 GB fluctuation

The `reconcile` loop gains two specialized observers for this specific pattern:

**Observer: `purgeable_watch`**
- Reads `diskutil info /` every 60 s, tracks `Purgeable Space`
- When `df_free < 2 GB AND purgeable > 4 GB`:
  - Log the event (for the history graph)
  - Action 1: `sudo tmutil thinlocalsnapshots / 10000000000 4` (thin to 10 GB)
  - Action 2: If still pressured, `rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex`
  - Action 3: If still pressured, restart Docker Desktop (triggers VM disk TRIM)

**Observer: `clang_cache_watch`**
- Monitors `/var/folders/*/C/clang` and `/var/folders/*/C/org.llvm.clang`
- When cache > 500 MB AND no active compiler process → rotate
- This is a minor optimization but saves ~500 MB per rotation

**User-facing output** (`lfg devdrive history`):
```
DevDrive pressure — last 24 h
----------------------------------------
Time        df_free   cont_free  purge   snapshots  action
-----       -------   ---------  -----   ---------  ------
00:00       52.1 GB    53.4 GB   1.3 GB  2          (boot)
00:30       48.9 GB    53.2 GB   4.3 GB  3          (snapshot)
01:15       46.2 GB    52.8 GB   6.6 GB  3          clang cache +500 MB
03:00       42.1 GB    48.1 GB   6.0 GB  4          xcode index +2.1 GB
05:30       28.4 GB    40.2 GB  11.8 GB  4          docker +3.1, swift +1.2
05:37        3.2 GB     5.3 GB   2.1 GB  3          PRESSURE: thin snapshots -> +2.1 GB
05:45        1.0 GB     5.1 GB   4.1 GB  3          PRESSURE: docker prune -> +700 MB
06:00        3.5 GB    14.8 GB  11.3 GB  2          PRESSURE: tmutil thin -> +10 GB
----------------------------------------
Range in period: 1.0 GB - 52.1 GB (delta 51.1 GB)
Pressure events: 3 recoveries totaling 12.8 GB
Pattern: SAWTOOTH (expected for active Swift/Docker workload)
```

This directly visualizes the up/down the user is seeing, and labels each dip with its cause.

---

## 3. Concrete File Changes

```
~/tools/@yj/lfg/
├── DEVDRIVE_V2_DESIGN.md             [NEW] this doc
├── lib/
│   ├── devdrive.sh                    [MODIFIED] add `doctor`, `reconcile`, `adopt`, `pressure`, `history`, `migrate` verbs
│   └── devdrive-v2-migrate.sh         [NEW] migration-only script (copied into pkg-build)
├── io.lfg.devdrive-reconcile.plist    [NEW] LaunchAgent for 5-min reconcile loop
└── io.lfg.devdrive-automount.plist    [DEPRECATED] keep for v1 systems, remove after migration

~/tools/yj-devdrive/
├── btau/core/
│   ├── reconcile.py                   [NEW] reconcile loop entry point
│   ├── observers.py                   [NEW] purgeable_watch, clang_cache_watch, band_bloat_watch
│   ├── actions.py                     [NEW] repair actions (idempotent, dry-run aware)
│   ├── apfs_volume.py                 [NEW] native APFS volume creation / deletion
│   ├── migrate_v1.py                  [NEW] sparseimage -> APFS volume migration
│   └── sparse.py                      [UNCHANGED] kept for v1 compat during migration
├── tests/
│   ├── test_reconcile.py              [NEW]
│   ├── test_observers.py              [NEW]
│   ├── test_actions.py                [NEW]
│   └── test_apfs_volume.py            [NEW]

~/.config/lfg/
├── devdrive_state.json                [NEW] replaces devdrive_forest.json (migrated in-place)
├── devdrive_forest.json               [DEPRECATED] kept during migration, read-only
└── reconcile_log.jsonl                [NEW] append-only event log

~/Library/LaunchAgents/
└── io.lfg.devdrive-reconcile.plist    [NEW] 5-min interval reconcile
```

---

## 4. Build Sequence (suggested wave plan)

Intended for `/upm plan` + `/upm build` pipeline once user approves.

**Wave 1 — observability (no behavior change)**
- `observers.py` (all four watchers, read-only)
- `lfg devdrive pressure` (prints snapshot of current pressure)
- `lfg devdrive history` (prints ring buffer)
- Reconcile loop in **dry-run-only** mode
- Tests

**Wave 2 — reconcile actions (repair with user confirm)**
- `actions.py` (all repair actions)
- `lfg devdrive reconcile --apply`
- Confirmation prompt before first apply
- Tests

**Wave 3 — APFS backend**
- `apfs_volume.py` (create, delete, rename, quota adjustment)
- `lfg devdrive adopt` switches to APFS volume creation for new projects
- Sparseimage path kept intact for existing volumes
- Tests

**Wave 4 — migration**
- `migrate_v1.py`
- `lfg devdrive migrate v1-to-v2` CLI
- Manual rollback procedure documented
- Manual user run per volume with prompts
- No LaunchAgent change yet

**Wave 5 — LaunchAgent swap**
- Install `io.lfg.devdrive-reconcile.plist`
- Remove `io.lfg.devdrive-automount.plist` (no longer needed after migration)
- Verify reboot auto-mounts work via APFS

**Wave 6 — Menubar integration**
- `lfg-menubar` gets a new "DevDrive pressure" indicator
- Shows current df_free with color-coded threshold
- Click → shows history graph in WebKit viewer

---

## 5. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| APFS volume quota exceeded, writes fail | Med | High | Reserve 5% headroom, emit APM warning at 80% |
| Migration rsync corrupts data | Low | Critical | shasum sample verify; keep v1 image 24 h |
| Reconcile loop loops forever under pressure | Low | Med | Hard 60 s per-cycle budget; exponential backoff between cycles |
| Reconcile triggers during active build | Med | Low | Action scheduler checks for running `clang`, `swift`, `docker build`, `xcodebuild` PIDs before compacting or pruning |
| Auto-rsync relocates a dir an app still has open | Low | High | Check `lsof` for write handles before replacing; retry next cycle |
| LaunchAgent fails to load after reboot | Low | Med | Keep v1 automount plist present until reconcile has successfully run once post-reboot |
| APFS snapshot deletion nukes user Time Machine | Low | Critical | Only thin local snapshots (`tmutil thinlocalsnapshots`), never delete backup snapshots |
| User has FileVault enabled and APFS add fails | Low | Med | Detect FileVault state before migration, fall back to unencrypted volume with warning |

---

## 6. Open Questions for User

1. **Quota assignment**: what's the right per-volume cap? (Current sparseimages have hardcoded sizes — DDRV900 4 GB, DDRV901 10 GB, DDRV902 ~150 MB, DDRV903 500 GB). Should v2 keep these, double them, or derive from observed usage?
2. **Reconcile default**: dry-run or auto-apply? I recommend dry-run with an explicit `lfg devdrive reconcile --enable-apply` one-time opt-in.
3. **Rollback window**: 24 h grace before deleting v1 sparseimages, or longer?
4. **ZFS v3 appetite**: is there interest in eventually moving to OpenZFS for real self-healing (scrubs, checksums, CoW), or is APFS native "good enough"?
5. **Pressure response aggressiveness**: should the loop auto-thin snapshots without asking, or always prompt? (Default answer: auto-thin at `df_free < 1 GB`, prompt at `< 5 GB`.)

---

## 7. Appendix: Observed State Snapshot (2026-04-11)

```
Root volume:
  /dev/disk3s1s1  460 Gi total, 22 Gi used, 1.0 Gi visible free (96%)
  container free:  5.1 GB  (of which 4.1 GB purgeable)

Active sparseimages:
  ~/DevDrive/900HOOKS.dmg.sparseimage   -> /Volumes/DDRV900      (3.8 GB vol)
  ~/DevDrive/901DEVLIB.dmg.sparseimage  -> /Volumes/DDRV901      (9.8 GB vol)
  ~/DevDrive/902APMDR.dmg.sparseimage   -> /Volumes/DDRV902      (151 MB vol)
  ~/DevDrive/904MEMVT.dmg.sparseimage   -> /Volumes/DDRV-904-MEMVT (15.2 GB vol)
  ~/.config/btau/903LUME.sparsebundle   -> /Volumes/DDRV903      (500 GB vol, 165 bands, 1.2 GB host)
  ~/.config/btau/920COWORK.sparsebundle -> /Volumes/920COWORK    (207 bands, 1.5 GB host)
  ~/.config/btau/devdrive.sparseimage   -> /Volumes/devdrive     (10 MB, 900DEVELOPER forest root)

Symlink forest (from devdrive_forest.json):
  ~/Library/Caches/Homebrew    -> DDRV902/caches/homebrew   [drift-fixed 05:39]
  ~/Library/Caches/pip         -> DDRV902/caches/pip        [healthy]
  ~/Library/Caches/pnpm        -> DDRV902/caches/pnpm       [healthy]
  (+ 6 more cache rules)

APFS local snapshots: 4 (all com.apple.os.update-* — locked)

Docker:
  VM raw file: 5.0 GB host / 461 GB apparent sparse
  Internal state: 362 MB images, 0 GB cache, 5 active containers
```

---

## 8. Related Docs

- `~/.claude/agents/lfg/devdrive-agent.md` — current agent spec (v1)
- `~/.claude/commands/lfg.md` — user-facing command reference
- `~/tools/yj-devdrive/btau/core/sparse.py` — current hdiutil wrapper
- `~/tools/yj-devdrive/btau/core/devdrive.py` — current forest builder
- `~/tools/@yj/lfg/lib/devdrive.sh` — current CLI wrapper
- `~/.config/lfg/devdrive_forest.json` — current forest state

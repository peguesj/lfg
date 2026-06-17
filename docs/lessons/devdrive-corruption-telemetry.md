# DevDrive Corruption Telemetry — Lessons & Self-Corrective Reconcile Path

**Status**: draft v1 (2026-06-09)
**Author**: lfg-devdrive recovery analysis
**Companion corpus**: [`devdrive/corpus/incidents.ndjson`](../../devdrive/corpus/incidents.ndjson)
**Companion sketch**: [`devdrive/corruption_detector.py`](../../devdrive/corruption_detector.py)

---

## 1. Why

Every DevDrive corruption to date has left a distinctive signature in `hdiutil`/`fsck_apfs` output. The 2026-06-09 session alone produced two recovery-log entries whose root signals already match the 904MEMVT rebuild precedent from May, and whose recovery actions are mechanical once the failure class is named. The gap is collection: the LFG daemon does not yet snapshot those signals on mount/reconcile events, so it cannot detect-and-recover before the user notices a broken symlink. This document distills the failure-class catalog, defines the telemetry contract for `STFU`/`DEVDRIVE`, and sketches the detector that would consume it.

---

## 2. Failure class catalog

| Class | hdiutil signature | fsck_apfs signature | Recoverability | Suggested action |
|---|---|---|---|---|
| `apfs-superblock-errno-5` | `Resource busy` / superblock invalid (errno 5) at block 0 | container superblock fails | none in place; rebuild on new volume | `quarantine-and-rebuild` |
| `extent-ref-btree-zeroed` | attaches; `diskutil mount` returns `DIHLDiskImageAttach error 112` | aborts at extent-ref tree with `apfs_extentref: btn: found zeroed-out block` and an `(oid 0x...)` annotation | none with stock macOS tooling (Apple ships no extent-ref rebuilder; apfs-fuse needs FUSE-3 which is not packaged for macOS) | `quarantine-and-rebuild` |
| `transient-probe-false-positive` | errno 5 reported on first probe at one `/dev/diskN`, clean on subsequent probe at a different slice | n/a | full | `observe` (debounce ≥1 reprobe before any volume action) |
| `fleet-schema-drift` | n/a — volume is healthy | n/a | full | `lint` (no volume action; surface as a schema warning in `FleetRegistry.load()`) |
| `stale-attach-after-host-reconnect` | image is attached but `diskutil mount` fails immediately after host reconnect | clean once detached and reattached | full | `detach-and-reattach` (single retry); only escalate if a second probe still fails |

Provenance for each class is in the [incidents corpus](../../devdrive/corpus/incidents.ndjson); the four NDJSON records cover 904MEMVT (May), 900HOOKS (false positive, 2026-06-09), 903CLAUD (extent-ref, 2026-06-09), and 920COWORK (schema drift, 2026-06-09).

---

## 3. Telemetry contract

Every mount, reconcile, and detach event in `STFU` and `DEVDRIVE` should emit a record matching the `diagnostic_signals` shape in the corpus. Required fields:

| Field | Source | Notes |
|---|---|---|
| `hdiutil_info_block` | `hdiutil info -plist` filtered to the image path | full plist block, not just the dev path — slice numbers change across reconnects |
| `hdiutil_attach_error` | stderr of `hdiutil attach -nomount <image>` | preserve the exact "Error N" / "Resource busy" string; the classifier keys off it |
| `fsck_apfs_first_failing_check` | first non-OK line of `fsck_apfs -nl /dev/disk*s1` | e.g. `extent ref tree`, `container superblock`, `object map` |
| `fsck_apfs_node_oid` | the `(oid 0x...)` annotation on the first error line, if present | high-value for incident dedup; `0x1cead6` on 903CLAUD was a perfect match key |
| `fsck_apfs_block` | the trailing block number on `apfs_extentref: btn: dev_read_finish(<block>, 1)` | needed to compute which band the corruption lives in (`block * 4096 / band_size_bytes`) |
| `info_plist_vs_bckup_diff` | `cmp Info.plist Info.bckup` for sparsebundles | `identical` rules out a metadata bit-flip; `differs` is its own class |
| `band_count` | `ls -1 <bundle>/bands/ \| wc -l` | sparsebundle-only |
| `band_mtime_range` | `find <bundle>/bands -type f -exec stat -f '%Sm' ...` min/max | used to bracket "last clean write" — within 60s of an unclean detach is the danger zone |
| `host_disconnect_events_72h` | `log show --predicate 'subsystem == "com.apple.NSWorkspace"'` filtered for `didUnmountNotification` involving the host | feeds the debounce heuristic |
| `stale_attach_events_72h` | LFG's own `state.json` history of "attached but unmountable" observations | second-level confirmation |

These records should be appended one-per-line to `~/.config/lfg/telemetry/incidents.ndjson` and, on each append, also written to the canonical corpus via a lightweight `git-style` add (the LFG daemon owns its own log; the repo corpus at `devdrive/corpus/incidents.ndjson` is the curated/redacted subset).

**Tags** (consume from the corpus, do not invent at emit time):
- `failure_class` is set by the detector, not by the emitter. Emitters write raw signals only.
- `incident_id` follows `ldcv-YYYY-MM-DD-<volume-id-lower>`.

---

## 4. Proposed `corruption_detector.py`

The detector reads `devdrive/corpus/incidents.ndjson` plus live `hdiutil info` / `fsck_apfs -nl` output and returns `(failure_class, confidence, suggested_action)`. A 50-line sketch lives at `devdrive/corruption_detector.py`; the real implementation is LFG-83/84 story work and intentionally out of scope here.

Heuristic order the sketch encodes:

1. Exact `fsck_apfs_node_oid` match against the corpus → confidence ≥ 0.9.
2. Same `fsck_apfs_first_failing_check` + same band-count bucket → confidence ≈ 0.6.
3. Same `hdiutil_attach_error` string only → confidence ≈ 0.3, suggested_action forced to `observe` (debounce).
4. No match → `("unknown", 0.0, "observe")`. Never `rebuild` on unknown.

Suggested-action vocabulary, kept deliberately small: `observe`, `detach-and-reattach`, `lint`, `quarantine-and-rebuild`, `salvage-attempt`, `no-op`.

---

## 5. Wiring

Concrete insertion points in the existing modules. **None of these edits are part of this deliverable** — they belong to LFG-83 (Swift `MountOrchestrator` parity) and LFG-84 (bash parity in `devdrive-automount.sh` / `devdrive-reconcile.sh`).

### `lib/devdrive.sh`

- **Around line 165** (`# Parse hdiutil info for this image`): after the existing `subprocess.run(["hdiutil", "info"], ...)` block, snapshot the full per-image plist block into the telemetry record before the parser narrows it down to `dev_disks`. This is where `hdiutil_info_block` is captured.
- **Inside `attach_image()` at line 557**, immediately after the `subprocess.run(["hdiutil", "attach", ...])` call returns: capture `result.stderr` verbatim as `hdiutil_attach_error` regardless of success — the success path still emits useful "warning" stderr lines.
- **At line 594** (`hdiutil attach failed:` branch): before returning `False`, emit a record with `suggested_action_input=detect(image)` so the daemon can decide whether to retry-with-detach or escalate.
- **Around line 590** (`hdiutil attach succeeded but mount point not found at {mount}`): this is the `stale-attach-after-host-reconnect` signature. Emit a record with that exact suggested action.

### `lib/stfu.sh`

- **Line 116** and **line 213** already call `lfg_notify_apm` for STFU archive / scaffold events. The same notify shim is the right place to fan out the telemetry record — extend `lfg_notify_apm` (defined in `lib/common.sh`, not shown here) to also append to `~/.config/lfg/telemetry/incidents.ndjson` when the event class is `devdrive.*`.
- STFU's process-noise scan is also a natural place to detect "process X is holding open files on the volume we are about to detach" — that's the precondition that produces `extent-ref-btree-zeroed`. Adding a pre-detach lsof scan as a telemetry-only field (no behaviour change) would let the corpus grow a `preceding_signals.open_handles_at_detach` series.

### `lib/btau.sh`

- The 904MEMVT v2 rebuild precedent encoded here is the template the detector recommends for `apfs-superblock-errno-5` and `extent-ref-btree-zeroed`. No edit required, but document the pattern in this file's header so future operators recognise it.

---

## 6. Out of scope for this doc

- Implementing `corruption_detector.classify()` (stub only — LFG-83).
- Editing `lib/devdrive.sh` or `lib/stfu.sh` (LFG-83/84 ship the wiring).
- macFUSE / FUSE-3 packaging for `apfs-fuse` salvage (separate decision; see §3 of the 903CLAUD recovery log).
- Schema lint rule in `FleetRegistry.load()` for the `fleet-schema-drift` class (LFG-82).

When those land, this document gets one new section per ship (one paragraph each) and one new incident per real corruption — keeping the corpus as the source of truth for everything the detector has actually seen.

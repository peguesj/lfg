# FSKit / macFUSE 5.2 Overlay — POC Findings

**Status**: DRAFT — pending actual benchmark runs on Apple Silicon hardware  
**Story**: US-007 (LFG DevDrive v2)  
**Date**: 2026-04-14  
**Author**: LFG DevDrive v2 team

---

## 1. Executive Summary

This document records design decisions, technical findings, and a go/no-go
recommendation for the FUSE overlay approach explored in `lib/devdrive_v2/overlay.py`.
The goal was to determine whether a Python-based FUSE layer can serve as a
unified namespace router over multiple APFS sparse-image volumes without
introducing unacceptable I/O overhead for developer workloads.

---

## 2. Architecture

```
┌───────────────────────────────────────────────────────┐
│              Developer tools / shells / IDEs           │
└─────────────────────────┬─────────────────────────────┘
                          │  POSIX syscalls (open, read, …)
                          ▼
┌───────────────────────────────────────────────────────┐
│          OverlayFS (FUSE — /mnt/devdrive)              │
│                                                       │
│  _resolve("/projects/foo")  →  /Volumes/DDRV904/…    │
│  _resolve("/hooks/pre-commit") → /Volumes/DDRV900/…  │
│  _resolve("/cache/npm")    →  /Volumes/DDRV901/npm   │
│                                                       │
│  Route rules (prefix → volume + subpath)              │
│  evaluated in declaration order; first match wins     │
└──────┬───────────────────┬───────────────────┬────────┘
       │                   │                   │
       ▼                   ▼                   ▼
/Volumes/DDRV904    /Volumes/DDRV900    /Volumes/DDRV901
  (APFS sparse)       (APFS sparse)       (APFS sparse)
```

### Component roles

| Component | Responsibility |
|-----------|---------------|
| `OverlayConfig` | Immutable routing table; validated at construction |
| `OverlayFS._resolve()` | O(n-rules) prefix scan; first match wins |
| `OverlayFS.mount()` | Calls `fuse.FUSE()`; blocks in FUSE event loop |
| `OverlayFS.unmount()` | Calls `diskutil unmount` (macOS) or `fusermount -u` |
| `measure_performance()` | Create/read/delete benchmark stub; no FUSE dependency |

### Routing semantics

Given route rules:

```json
[
  {"prefix": "/projects", "volume": "DDRV904", "target_subpath": "projects"},
  {"prefix": "/hooks",    "volume": "DDRV900", "target_subpath": "hooks"},
  {"prefix": "/cache",    "volume": "DDRV901", "target_subpath": ""}
]
```

| Virtual path | Resolved real path |
|---|---|
| `/projects` | `/Volumes/DDRV904/projects` |
| `/projects/foo/bar` | `/Volumes/DDRV904/projects/foo/bar` |
| `/hooks/pre-commit` | `/Volumes/DDRV900/hooks/pre-commit` |
| `/cache` | `/Volumes/DDRV901` |
| `/cache/npm` | `/Volumes/DDRV901/npm` |
| `/docs` (no match) | `/Volumes/DDRV904/docs` (default volume) |

---

## 3. macFUSE 5.2 / FSKit Context

macFUSE 5.2.0 was released 2026-04-09.  Key changes relevant to this POC:

* **FSKit backend** — On Apple Silicon (M1 and later), macFUSE can now use
  Apple's FSKit framework as its in-kernel transport rather than a `.kext`.
  This eliminates the need to disable System Integrity Protection or install a
  kernel extension manually.
* **Intel Macs** — The legacy `.kext` path remains available for Intel Macs
  running macOS 13+.  SIP must still be partially relaxed on older hardware.
* **Python binding** — `fusepy` (`pip install fusepy`) wraps `libfuse`/`libosxfuse`
  and is compatible with macFUSE 5.x.  No code changes are needed in the overlay
  module to take advantage of the FSKit backend; the switch is transparent at
  the OS level.

---

## 4. Known Limitations

### 4.1 Operational

| Limitation | Detail |
|---|---|
| macFUSE must be installed | `fusepy` requires `libosxfuse` from the macFUSE installer; not bundled with macOS |
| Blocking mount | `OverlayFS.mount()` runs the FUSE event loop in the calling thread; production use needs a daemon process or background thread |
| Cross-volume rename not supported | `rename(2)` across two different volume prefixes raises `EXDEV`; callers must copy-and-delete |
| No hard links across volumes | Same root cause as cross-volume rename |
| No extended-attribute passthrough | `getxattr`/`setxattr` are not yet implemented |
| Single-threaded prototype | `nothreads=False` is passed to `fuse.FUSE()` but no locking guards are in place; concurrent writes to the same file are unsafe |

### 4.2 Deployment

* The FUSE mount point must be created before calling `mount()` (handled automatically).
* The overlay is not persistent across reboots; a launchd plist or login hook is
  required to re-mount after restart.
* `diskutil unmount` is used on macOS; `fusermount -u` is used elsewhere (Linux CI).

---

## 5. Performance Expectations

FUSE introduces a user–kernel transition on every syscall routed through the
overlay.  Typical overhead estimates based on published macFUSE benchmarks and
the FSKit baseline:

| Operation | Direct APFS | FUSE overhead (estimated) | Net (FUSE) |
|---|---|---|---|
| `open()` | ~2 µs | +50–100 µs | ~52–102 µs |
| `read()` 4 KB | ~5 µs | +50–150 µs | ~55–155 µs |
| `write()` 4 KB | ~8 µs | +50–200 µs | ~58–208 µs |
| `stat()` | ~1 µs | +30–80 µs | ~31–81 µs |

**FSKit backend improvement**: Early reports from macFUSE 5.2 indicate the FSKit
path reduces average syscall overhead by ~30–40% vs the kext path on Apple
Silicon, putting the per-call floor closer to 50 µs rather than 150+ µs.

These figures are estimates.  Actual numbers depend on CPU governor state, APFS
encryption, and concurrent I/O from other processes.  Run `measure_performance()`
against a live overlay to obtain project-specific baselines.

### 5.1 Acceptable overhead thresholds (proposed)

| Workload | Max acceptable overhead |
|---|---|
| Source file reads (IDE indexing) | < 200 µs / call |
| Build artefact writes (compiler output) | < 300 µs / call |
| Package cache reads (npm, pip) | < 150 µs / call |
| Git operations (status, diff, log) | < 500 µs aggregate |

---

## 6. Go / No-Go Criteria

### Go — proceed to production integration

All of the following must be true:

- [ ] Benchmark `measure_performance()` on Apple Silicon M-series Mac shows
      mean per-operation overhead < 200 µs for 1 000-op runs.
- [ ] IDE indexing (Xcode, VS Code with pylsp) is not measurably slower
      (< 5% increase in index time) when operating over the overlay.
- [ ] `git status` on a 50k-file repository over the overlay completes in
      < 5 s (same order of magnitude as direct APFS).
- [ ] No data corruption detected in a 24-hour soak test with concurrent
      reads/writes from two processes.
- [ ] macFUSE 5.2 installer can be packaged into the LFG `.pkg` without
      requiring SIP relaxation on Apple Silicon.

### No-Go — abandon FUSE overlay

Any of the following triggers a no-go recommendation:

- Any benchmark showing > 500 µs median overhead on common operations.
- Data integrity issues (checksum mismatches, truncated writes) during soak.
- macFUSE licensing terms are incompatible with LFG distribution requirements.
- Apple Silicon FSKit backend unavailable in a future macOS release.

### No-Go alternative

If the overlay approach is abandoned, the recommended fallback is **symlink
forest** (already implemented in `lib/devdrive_v2/reconcile.py`) with an
`~/.zshrc` `CDPATH` / `PATH` shim — zero overhead, zero kernel dependencies.

---

## 7. Next Steps

1. **Run `measure_performance()`** on a live macFUSE 5.2 overlay and record
   actual latency numbers in a follow-up version of this document.
2. **Soak test** — 24-hour concurrent read/write with two processes.
3. **IDE smoke test** — VS Code Remote with pylsp over the overlay mount.
4. **launchd plist** — Add an auto-mount agent so the overlay persists across
   reboots.
5. **`getxattr`/`setxattr` passthrough** — Required for Finder tags and
   extended metadata used by some developer tools.
6. **Update this document** with real benchmark data and flip status from
   DRAFT to FINAL.

---

*DRAFT — benchmarks pending. Do not use this document for go/no-go decisions
until the soak test and benchmark results are recorded.*

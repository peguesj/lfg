# LFG Formation — Implementation Plan

Formation: fmt-lfg-fleet-20260419
Branch: develop

---

## Wave 1 — Foundation: SPM Structure on develop

**Goal**: Establish Swift Package Manager structure on develop; all targets compile.

Tasks:
- Merge `swiftui-port` Package.swift into develop
- Add `LFGDaemon` executableTarget to Package.swift
- Create stub `Sources/LFGDaemon/main.swift`
- Create stub `Sources/LFGKit/` and `Sources/LFGApp/` source files
- Create stub `Tests/LFGKitTests/` with one passing no-op test
- Verify: `swift build` exits 0, `swift test` exits 0

Backpressure gate: `swift build 2>&1` must succeed before Wave 2 begins.

---

## Wave 2 — Daemon: XPC Service + FSEvents Watcher

**Goal**: `LFGDaemon` XPC service watches `/Volumes` and exposes `LFGDaemonProtocol`.

Spec: `specs/daemon-xpc.md`

Tasks:
- Implement `FSEventsWatcher` in LFGKit (wraps `FSEventStream`)
- Implement `FleetRegistry` (loads/saves fleet.json v2)
- Implement `VolumeEventHandler` (attach/detach decisions)
- Implement `LFGDaemonService` (XPC listener, adopts `LFGDaemonProtocol`)
- Write `io.lfg.daemon.plist` LaunchAgent
- TDD: `VolumeEventHandlerTests`, `FleetRegistryTests`, `XPCProtocolTests`, `DebounceTests`

Backpressure gate: `swift test` passes all daemon-related tests before Wave 3.

---

## Wave 3 — App Operations: Mount/Unmount/Repair Controls

**Goal**: `LFGApp` SwiftUI views for volume management, offload, and symlink repair.

Spec: `specs/native-app-operations.md`

Tasks:
- Implement `DaemonClient` (NSXPCConnection wrapper with reconnect + timeout)
- Implement `OffloadOperation` (mv + ln -s, rollback on failure)
- Implement `SymlinkAuditor` (scan for dangling/wrong-target links)
- Implement `PressureCalculator` (statfs wrapper, threshold classification)
- Build `DevDriveView`, `OffloadPanel`, `SymlinkRepairView`, `PressureMonitorView`
- Build MenuBar popover (LFG Helper target)
- TDD: `OffloadOperationTests`, `SymlinkAuditorTests`, `DaemonClientTests`, `PressureCalculatorTests`

Backpressure gate: `swift test` passes all app-operation tests; `swift build` clean.

---

## Wave 4 — DevDrive v2: APFS Backend + Migration

**Goal**: Fleet registry v2 schema; reconcile loop as XPC-callable service; migration tool.

Spec: `specs/devdrive-v2-backend.md`

Tasks:
- Update `FleetRegistry` to parse/write v2 schema (version field, `backend`, `container`)
- Implement `ReconcileService` (idempotent steps; XPC-callable; skips offload symlinks)
- Extend `devdrive/migrate_v1.py` with dry-run and v1→v2 migration steps
- Update `io.lfg.devdrive-reconcile.plist` to call daemon XPC instead of direct script
- TDD: `FleetRegistryV2Tests`, `ReconcileLoopTests`, `MigrationTests`
- Merge `devdrive-v2-native` branch (cherry-pick APFS volume management helpers)

Backpressure gate: `swift test` passes all reconcile/registry tests; `python3 -m pylint devdrive/*.py` 0 errors.

---

## Wave 5 — UX Polish: Native Module Views

**Goal**: All 5 module views (WTFS, DTF, BTAU, DevDrive, SSD) in native SwiftUI; WebKit removed.

Spec: `specs/ux-refactor.md`

Tasks:
- Implement design token files (`LFGColors`, `LFGSpacing`, `LFGTypography`)
- Implement `WTFSViewModel` + `WTFSView`
- Implement `DTFViewModel` + `DTFView`
- Implement `BTAUViewModel` + `BTAUView`
- Implement `SSDViewModel` + `SSDView`
- Wire `NavigationSplitView` sidebar with all module views
- Apply consistent `ToolbarItemGroup` pattern
- TDD: `WTFSViewModelTests`, `DTFViewModelTests`, `SSDViewModelTests`, `DesignTokenTests`
- Delete `viewer.swift`, `menubar.swift`, `.lfg_*.html` files
- Verify: no `WKWebView` import anywhere in Sources/

Backpressure gate: `swift build -Xswiftc -warnings-as-errors` exits 0.

---

## Wave 6 — TDD Completion: 80%+ Coverage

**Goal**: Close test gaps; reach 80% line coverage across all targets.

Tasks:
- Run `swift test --enable-code-coverage`; generate `llvm-cov` report
- Identify uncovered paths; write targeted tests
- Fix any flaky tests (async timing, temp file races)
- Ensure `shellcheck lib/*.sh scripts/*.sh` exits 0
- Ensure `python3 -m pylint devdrive/*.py` exits 0
- Document any intentionally untested code with `// LCOV_EXCL`

Backpressure gate: coverage report shows ≥ 80% line coverage on LFGKit and LFGDaemon.

---

## Wave 7 — Integration: APM Bridge + Plane PM + Release Build

**Goal**: APM notifications wired; Plane stories closed; release binary produced.

Tasks:
- Wire daemon `POST http://localhost:3032/api/notify` on reconcile completion
- Update CCEM APM bridge at `~/Developer/ccem/apm/bridges/lfg-devdrive.json`
- Close Plane stories LFG-60..LFG-65 via API
- Run `swift build -c release`; verify binary sizes reasonable
- Update `README.md` with new architecture overview
- Tag release: `git tag v2.0.0`

Backpressure gate: `swift build -c release` exits 0; APM dashboard reflects LFG project activity.

---

## Risk Register

| Risk | Mitigation |
|------|-----------|
| YJ_MORE disconnect during tests | MockDiskutil prevents real volume ops in test suite |
| XPC sandbox entitlements | Wave 2 includes entitlement file + `com.apple.security.temporary-exception` as needed |
| swiftui-port merge conflicts | Wave 1 resolves all conflicts before any Wave 2+ work |
| `diskutil` API changes across macOS versions | Pin to macOS 14 minimum; test on 14 and 15 in CI |
| FleetRegistry v1→v2 data loss | Migration always preserves sparseimage until verified; full rollback path |

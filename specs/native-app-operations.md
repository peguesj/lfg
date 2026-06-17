# Spec: LFGApp — Native SwiftUI Operational Controls

## Purpose
A native SwiftUI macOS application (macOS 14+) providing a full-featured UI for DevDrive volume management, directory offload, symlink repair, pressure monitoring, and MenuBar quick controls.

## Target: LFGApp (Sources/LFGApp/)
Links against `LFGKit`. Communicates with `LFGDaemon` via XPC (`io.lfg.daemon`).

---

## Views

### 1. DevDrive Volume Manager
- List all volumes from `FleetState` (daemon XPC call)
- Per-volume row: name, host, status badge (mounted/unmounted/error), size bar
- Actions per row: Mount, Unmount, Inspect (opens volume in Finder)
- Toolbar: "Mount All", "Unmount All", "Refresh"
- Empty state: guide user to run `lfg devdrive init`

### 2. Directory Offload Panel
- Source picker: choose a directory from `~` via `NSOpenPanel`
- Target picker: dropdown of mounted DevDrive volumes
- Estimated size display (computed async via `du -sh`)
- Dry-run preview: shows what will move and what symlink will replace it
- Execute button: calls `LFGKit.OffloadOperation` which performs `mv` + `ln -s`
- Progress sheet with cancellation

### 3. Symlink Repair View
- Scan button: invokes `LFGKit.SymlinkAuditor.scan(root: URL)` — returns array of `SymlinkIssue`
- Issue table: path, type (dangling / wrong-target / missing-host-volume), severity
- Per-issue actions: Repair (auto), Skip, Show in Finder
- Repair All button with confirmation alert
- Result summary: N repaired, M skipped, K failed

### 4. Pressure Monitor Dashboard
- Real-time ring charts (SwiftUI Canvas): internal disk %, each DevDrive volume %
- Update interval: 5 seconds (Timer publisher)
- Alert thresholds configurable in Settings (default: warn at 80%, critical at 90%)
- Recent events list: last 20 daemon log entries, auto-refreshed
- Export log button → saves `daemon.log` snapshot to Downloads

### 5. MenuBar Helper (LFG Helper target)
- Shows disk pressure icon: green / yellow / red based on internal disk %
- Popover on click:
  - Internal disk usage summary
  - Volume rows with mount/unmount toggle
  - "Open LFGApp" button
  - "Reconcile Now" button (fires XPC `reconcile`)
- No dock icon (`LSUIElement = YES`)

---

## Settings (SwiftUI Settings scene)
- Auto-mount on external connect: Bool toggle (written to `~/.config/lfg/state.json`)
- Notification preferences: connect events, pressure alerts, reconcile results
- Pressure thresholds: warn %, critical %
- Log retention: 1MB / 10MB / 50MB ring buffer size

---

## XPC Integration
All daemon calls go through `LFGKit.DaemonClient` (wraps `NSXPCConnection`):
- Lazy connection; reconnects on interruption
- 5-second timeout on all async replies; surfaces `DaemonError.timeout` on expiry
- UI shows inline error banner (not modal) on daemon unreachable

---

## TDD Requirements

### Unit tests (Tests/LFGKitTests/)
- `OffloadOperationTests`: verify mv + symlink creation using temp directories; rollback on failure
- `SymlinkAuditorTests`: scan a synthetic directory tree with known dangling links; verify all issues detected
- `DaemonClientTests`: mock XPC; verify reconnect logic and timeout surfacing
- `PressureCalculatorTests`: feed mock `statfs` results; verify percentage and threshold classification

### UI tests (Tests/LFGAppUITests/ — future wave)
- Smoke test: launch app, confirm volume list loads without crash

### Coverage target
80% line coverage on `Sources/LFGApp/` view models and `LFGKit` operational types.

## Acceptance Criteria
- Mount/unmount actions complete within 3 seconds and update UI without manual refresh
- Offload of a 1GB directory succeeds end-to-end; symlink is valid post-operation
- Repair All resolves all synthetic dangling links in test suite
- MenuBar popover appears within 200ms of click; does not block main thread

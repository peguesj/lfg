# Spec: LFGDaemon — XPC Service

## Purpose
A persistent background daemon that watches `/Volumes` for external drive connect/disconnect events and manages DevDrive sparseimage lifecycle automatically. Exposed to `LFGApp` via an XPC protocol.

## FSEvents Watcher

### Trigger paths
- `/Volumes` — top-level directory to detect volume mounts/unmounts

### Event handling logic
- On path creation under `/Volumes`: check if the new directory matches a known host in `fleet.json` (e.g., `YJ_MORE`)
- On host-volume appear: iterate fleet.json entries whose `host` matches; attach each sparseimage via `hdiutil attach`
- On path removal under `/Volumes`: detect disconnect; gracefully detach associated sparseimages via `hdiutil detach -force`
- Debounce consecutive events within 500ms window to avoid thrash on rapid mount/unmount sequences

### State
- Maintain in-memory map of `volumeName → mountPoint` derived from fleet.json
- Persist event log to `~/.config/lfg/daemon.log` (ring buffer, max 10MB)

## XPC Protocol

### Service identifier
`io.lfg.daemon`

### Protocol: `LFGDaemonProtocol`
```swift
@objc protocol LFGDaemonProtocol {
    func status(reply: @escaping ([String: Any]) -> Void)
    func mountVolume(_ name: String, reply: @escaping (Bool, String) -> Void)
    func unmountVolume(_ name: String, reply: @escaping (Bool, String) -> Void)
    func reconcile(reply: @escaping (Bool, String) -> Void)
    func fleetState(reply: @escaping (Data) -> Void)    // JSON-encoded FleetState
}
```

### Codable types (in LFGKit)
- `FleetState`: array of `VolumeRecord` (name, host, mountPath, status, lastSeen)
- `DaemonStatus`: uptime, watcherActive, lastEventAt, attachedVolumes

## LaunchAgent Persistence

### Plist: `io.lfg.daemon.plist`
- `RunAtLoad`: true
- `KeepAlive`: true
- `WatchPaths`: `/Volumes` (triggers if daemon crashes while drive is connected)
- `StandardOutPath`: `~/.config/lfg/daemon.log`
- `StandardErrorPath`: `~/.config/lfg/daemon-error.log`
- Installation path: `~/Library/LaunchAgents/io.lfg.daemon.plist`

## TDD Requirements

### Unit test targets (Tests/LFGKitTests/)
- `VolumeEventHandlerTests`: mock FSEvents callbacks; verify attach/detach decisions for known and unknown volumes
- `FleetRegistryTests`: fleet.json parsing, host matching, record mutation
- `XPCProtocolTests`: mock XPC connection; verify reply encoding/decoding for all four methods
- `DebounceTests`: verify 500ms debounce suppresses duplicate events

### Test doubles
- `MockHdiutil`: captures shell invocations; returns configurable success/failure
- `MockFleetRegistry`: in-memory fleet.json substitute
- `MockFSEventsStream`: fires synthetic add/remove events without touching the filesystem

### Coverage target
80% line coverage on `Sources/LFGDaemon/` and all LFGKit types used by the daemon.

## Acceptance Criteria
- Connecting YJ_MORE triggers automatic attach of DDRV-901 and DDRV-904 within 2 seconds
- Disconnecting YJ_MORE detaches those volumes without kernel panic or error log
- `LFGApp` can query daemon status and trigger manual mount/unmount via XPC
- LaunchAgent survives logout/login cycle

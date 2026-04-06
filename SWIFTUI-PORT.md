# LFG SwiftUI Port

## DO NOT MERGE TO MAIN WITHOUT EXPLICIT APPROVAL

This branch (`swiftui-port`) is an experimental port of LFG from the current Bash/Swift hybrid to a native SwiftUI application. It must never be merged to `main` without explicit sign-off.

---

## Architecture

### Overview
The SwiftUI port repackages LFG's five modules (WTFS, DTF, BTAU, DevDrive, SSD) as a native macOS app using:
- **SwiftUI** for the UI layer (macOS 14+ / Sonoma)
- **SwiftData** for persistent storage (disk snapshots, volume profiles, inbox items)
- **Swift Package Manager** for build/dependency management
- **MenuBarExtra** for always-available disk status in the menu bar
- **XPC** (planned) for privileged helper operations requiring root

### Target Stack
| Layer | Technology |
|-------|-----------|
| UI | SwiftUI (NavigationSplitView, LazyVGrid) |
| State | @Observable pattern (Observation framework) |
| Persistence | SwiftData (@Model) |
| Process execution | Foundation.Process (async wrapper) |
| Volume monitoring | NSWorkspace notifications |
| Spotlight control | mdutil CLI wrapper |
| CLI | swift-argument-parser |
| Privileged ops | XPC Services (future) |

### SPM Targets
| Target | Type | Purpose |
|--------|------|---------|
| `LFGApp` | executable | SwiftUI app with WindowGroup + MenuBarExtra |
| `LFGKit` | library | Shared utilities (SizeFormatter, ProcessRunner, Constants) |
| `lfg-cli` | executable | CLI interface using ArgumentParser |
| `LFGKitTests` | test | Unit tests for LFGKit |

### Directory Layout
```
Sources/
  LFGApp/
    LFGApp.swift              -- @main, WindowGroup, MenuBarExtra, SwiftData container
    AppState.swift            -- @Observable central state with disk info + module statuses
    Models/
      LFGModule.swift         -- Enum of all 5 modules with icons, colors, display names
      ModuleStatus.swift      -- Per-module run state (idle/running/completed/error)
      DiskSnapshot.swift      -- SwiftData @Model for disk usage history
      VolumeProfile.swift     -- SwiftData @Model for known volumes
      InboxItem.swift         -- SwiftData @Model for detected large files
    Services/
      DiskMonitorService.swift    -- FileManager disk polling
      VolumeWatcherService.swift  -- NSWorkspace mount/unmount events
      SpotlightService.swift      -- mdutil wrapper
      ProcessRunner.swift         -- Async Process wrapper
      InboxService.swift          -- Large file scanner
    Views/
      Sidebar.swift           -- NavigationSplitView sidebar with module list
      DashboardView.swift     -- Overview with disk gauge + module status grid
      MenuBarView.swift       -- MenuBarExtra window content
      WTFSView.swift          -- Placeholder
      DTFView.swift           -- Placeholder
      BTAUView.swift          -- Placeholder
      DevDriveView.swift      -- Placeholder
      SSDView.swift           -- Placeholder
    XPC/
      LFGPrivilegedProtocol.swift  -- XPC protocol definition
  LFGKit/
    SizeFormatter.swift       -- Human-readable byte formatting + parsing
    ProcessRunner.swift       -- Shared async Process wrapper for CLI/tests
    Constants.swift           -- Bundle IDs, paths, defaults
  lfg-cli/
    main.swift                -- CLI with status + scan subcommands
Tests/
  LFGKitTests/
    SizeFormatterTests.swift  -- Unit tests for SizeFormatter
```

---

## Wave Schedule

### Wave 1 -- Scaffold (this commit)
- SPM project structure and Package.swift
- @main app entry with WindowGroup + MenuBarExtra + SwiftData
- @Observable AppState with disk info polling
- LFGModule enum, ModuleStatus, SwiftData models
- ProcessRunner async wrapper
- Sidebar, DashboardView, MenuBarView (functional)
- Placeholder views for all 5 modules
- LFGKit: SizeFormatter, Constants, shared ProcessRunner
- lfg-cli with status and scan commands
- Unit tests for SizeFormatter

### Wave 2 -- WTFS Module
- Treemap visualization of disk usage (Charts framework)
- du/ncdu integration via ProcessRunner
- Directory drill-down navigation
- Snapshot history with SwiftData persistence

### Wave 3 -- DTF Module
- Cache directory scanning (~/Library/Caches, system caches)
- Safe deletion with dry-run preview
- Category grouping (Xcode, Homebrew, npm, pip, etc.)
- XPC helper for system cache paths

### Wave 4 -- BTAU Module
- Time Machine integration check
- Archive workflow (compress + move to external)
- Unused file detection heuristics
- Schedule-based backup reminders

### Wave 5 -- DevDrive Module
- Developer directory analysis (node_modules, .build, DerivedData)
- One-click cleanup for build artifacts
- Project size tracking over time

### Wave 6 -- SSD / Spotlight Module
- Per-volume Spotlight toggle
- Index rebuild triggers
- Volume health monitoring via DiskArbitration

### Wave 7 -- Polish
- XPC privileged helper for root operations
- Notifications (disk space warnings)
- Settings/Preferences window
- Sparkle auto-update integration
- App Store or notarized DMG distribution

---

## Migration from v2 (Bash/Swift Hybrid)

The current LFG v2 is a Bash-orchestrated suite with:
- `lfg` shell script as entry point
- `viewer.swift` (AppKit WebKit viewer)
- `menubar.swift` (AppKit menu bar app)
- Shell scripts per module in `lib/` and `scripts/`

The SwiftUI port replaces all of this with a single native app. During the transition:
- The `main` branch continues to ship the Bash/Swift hybrid
- This branch develops the SwiftUI replacement in parallel
- No breaking changes to `main` until the port is verified complete

---

## Build & Run

```bash
# Build all targets
swift build

# Run the CLI
swift run lfg-cli status
swift run lfg-cli scan --threshold 50MB

# Run tests
swift test

# Build the app (macOS GUI requires Xcode or xcodebuild)
swift build --product LFGApp
```

---

## Requirements
- macOS 14.0+ (Sonoma)
- Swift 5.10+
- Xcode 15.0+ (for GUI development)

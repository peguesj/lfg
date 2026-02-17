# LFG - Local File Guardian

## Project Overview

- **Name**: LFG - Local File Guardian
- **Working Directory**: `~/tools/@yj/lfg`
- **Type**: macOS disk management tool suite with WebKit UI and menubar integration

## Modules

### WTFS - Where's The Free Space
Disk usage analyzer that scans directories and presents storage breakdown via WebKit viewer.

### DTF - Delete Temp Files
Cache scanner and cleaner that identifies and removes temporary/cache files across common application directories.

### BTAU - Back That App Up
Backup manager for application data with scheduling and restore capabilities.

## Stack

- **Bash** - Core dispatcher and module scripts
- **Swift** - Native macOS components (viewer.swift for WebKit views, menubar.swift for status bar integration)
- **Python3** - HTML templating engine for safe multi-line content generation
- **HTML/CSS/JS** - WebKit-rendered UI views

## Key Paths

| Component | Path |
|-----------|------|
| Dispatcher | `~/tools/@yj/lfg/lfg` |
| Modules | `~/tools/@yj/lfg/lib/{scan,clean,btau,splash,dashboard}.sh` |
| State | `~/.config/lfg/state.json` |
| Swift sources | `~/tools/@yj/lfg/{viewer,menubar}.swift` |
| Theme | `~/tools/@yj/lfg/lib/theme.css` |
| UI JS | `~/tools/@yj/lfg/lib/ui.js` |
| Symlinks | `~/bin/{lfg,wtfs,dtf}` |

## Build Commands

```bash
# Compile WebKit viewer
swiftc -O -o viewer viewer.swift -framework Cocoa -framework WebKit

# Compile menubar app
swiftc -O -o lfg-menubar menubar.swift -framework Cocoa
```

## Integration

- **CCEM APM Bridge**: `~/Developer/ccem/apm/bridges/lfg-devdrive.json`
- **Related**: yj-devdrive/btau at `~/tools/yj-devdrive/btau/`

## Patterns

- Modules source `lib/state.sh` for status tracking
- HTML generated via `python3` (not sed) for safe multi-line templating
- WebKit viewer uses `WKScriptMessageHandler` for JS-to-native bridge
- Cross-module chaining via temp file polling
- Menubar watches `~/.config/lfg/state.json` via `DispatchSource`

# LFG - Local File Guardian v1.4.0

## Project Overview

- **Name**: LFG - Local File Guardian
- **Version**: 1.4.0
- **Working Directory**: `~/tools/@yj/lfg`
- **Type**: macOS disk management tool suite with WebKit UI and menubar integration

## Modules

### WTFS - Where's The Free Space
Disk usage analyzer that scans directories and presents storage breakdown via WebKit viewer.

### DTF - Delete Temp Files
Cache scanner and cleaner that identifies and removes temporary/cache files across common application directories.

### BTAU - Back That App Up
Backup manager for application data with scheduling and restore capabilities.

### DEVDRIVE - Developer Drive
Developer-focused volume management for mounting, unmounting, syncing, and verifying developer drives. Supports APFS volume operations with integrity verification.

**Commands**: `mount`, `unmount`, `sync`, `verify`, `status`

```bash
~/tools/@yj/lfg/lfg devdrive mount     # Mount developer drive
~/tools/@yj/lfg/lfg devdrive unmount   # Safely unmount
~/tools/@yj/lfg/lfg devdrive sync      # Sync drive contents
~/tools/@yj/lfg/lfg devdrive verify    # Verify drive integrity
~/tools/@yj/lfg/lfg devdrive status    # Show drive status
```

## Stack

- **Bash** - Core dispatcher and module scripts
- **Swift** - Native macOS components (viewer.swift for WebKit views, menubar.swift for status bar integration)
- **Python3** - HTML templating engine for safe multi-line content generation
- **HTML/CSS/JS** - WebKit-rendered UI views

## Key Paths

| Component | Path |
|-----------|------|
| Dispatcher | `~/tools/@yj/lfg/lfg` |
| Modules | `~/tools/@yj/lfg/lib/{scan,clean,btau,devdrive,splash,dashboard}.sh` |
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

## Skill Command Reference

LFG is registered as a Claude Code skill at `~/.claude/commands/lfg.md`.

| Subcommand | Description | Example |
|------------|-------------|---------|
| `/lfg scan [path]` | WTFS disk usage analysis | `/lfg scan ~/Developer` |
| `/lfg clean [--force]` | DTF cache cleanup (default: dry run) | `/lfg clean --force` |
| `/lfg backup [cmd]` | BTAU backup operations | `/lfg backup status` |
| `/lfg devdrive [cmd]` | DEVDRIVE volume management | `/lfg devdrive mount` |
| `/lfg status` | Show LFG state | `/lfg status` |
| `/lfg splash` | Open LFG WebKit viewer | `/lfg splash` |
| `/lfg dashboard` | Open combined dashboard | `/lfg dashboard` |

## Agent Squadron

5 specialized agents available in `~/.claude/agents/lfg/`:

| Agent | Purpose |
|-------|---------|
| `lfg-scan` | Disk usage analysis - runs WTFS scans, interprets results, recommends cleanup targets |
| `lfg-clean` | Cache cleanup - runs DTF discovery, categorizes caches, executes cleanup with safety checks |
| `lfg-backup` | Backup management - runs BTAU discovery, schedules backups, manages restore operations |
| `lfg-devdrive` | Developer drive management - mount/unmount/sync/verify operations with integrity checks |
| `lfg-monitor` | System monitoring - watches disk usage, state changes, alerts on thresholds |

## Integration

- **CCEM APM Bridge**: `~/Developer/ccem/apm/bridges/lfg-devdrive.json`
- **Claude Code Skill**: `~/.claude/commands/lfg.md`
- **Reference Registry**: `~/.claude/config/reference-registry.json` (triggers: lfg, disk, cache, cleanup, backup, devdrive, wtfs, dtf, btau)
- **Slash Commands**: `~/.claude/config/slash-commands.json` (registered as `/lfg`)
- **Related**: yj-devdrive/btau at `~/tools/yj-devdrive/btau/`

## Patterns

- Modules source `lib/state.sh` for status tracking
- HTML generated via `python3` (not sed) for safe multi-line templating
- WebKit viewer uses `WKScriptMessageHandler` for JS-to-native bridge
- Cross-module chaining via temp file polling
- Menubar watches `~/.config/lfg/state.json` via `DispatchSource`

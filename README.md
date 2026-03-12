# LFG — Local File Guardian

**v2.4.0** | macOS disk management tool suite with WebKit UI, menubar agent, and AI chat

---

## Modules

### WTFS — Where's The Free Space
Disk usage analyzer. Scans configured paths, ranks directories by size, generates a color-coded WebKit report. Integrates with DTF and BTAU for cross-module recommendations.

### DTF — Delete Temp Files
Cache scanner and cleaner. Identifies reclaimable space across 50+ cache targets spanning dev, build, app, AI, and system categories. Dry-run by default; `--force` to execute.

**Cache categories**: DEV (npm, pip, uv, Cargo, Homebrew, Go, Gradle, Maven, CocoaPods, Yarn, pnpm), BUILD (Puppeteer, Playwright, Electron, TypeScript, Turbo, Prisma), APP (Adobe, iMazing, Limitless), AI (Claude vm_bundles, Chrome ML models, Ollama models, Chrome OptGuide hints), SYS (logs), Docker images.

### BTAU — Back That App Up
Backup manager. Wraps `~/tools/yj-devdrive/btau` for sparse image lifecycle: create, mount, sync, verify. Reads manifest from `~/.config/btau/manifest.json`.

### DEVDRIVE — Developer Drive
Volume management for developer drives. Mount/unmount APFS sparse images, sync project trees, verify integrity, manage symlink forests. Supports multi-volume profiles with auto-move policies.

**Commands**: `mount`, `unmount`, `sync`, `verify`, `status`, `create`, `config`, `auto-move`

### STFU — Source Tree Forensics & Unification
Code forensics engine. Analyzes project portfolios for duplicate detection, shared dependency candidates, environment consolidation, and merge feasibility.

**Commands**: `deps`, `fingerprint`, `duplicates`, `libraries`, `envs`, `merge-check`, `scaffold`, `archive`

### Chat — AI Chat Interface
Multi-backend AI chat with agent routing. Runs HTTP server on `localhost:3033` with SSE streaming, conversation history, and semantic search integration.

**Backends**: Ollama (default), LiteLLM, Claude API
**Server**: `python3 lib/chat_server.py`
**CLI**: `lfg chat send "message"`

### Search — Semantic Search
Full-text search across projects, filesystem, and history using SQLite FTS5.

**Commands**: `search <query>`, `search index`, `search update`

### Dashboard
Aggregates WTFS, DTF, BTAU, DEVDRIVE, and STFU output into a single combined view with composition breakdown per project.

---

## Stack

| Layer | Technology |
|-------|-----------|
| Core dispatcher | Bash (`lfg`) |
| Module scripts | Bash (`lib/*.sh`) |
| Viewer app | Swift (AppKit + WebKit), `viewer.swift` |
| Menubar agent | Swift (AppKit + UserNotifications + ServiceManagement), `menubar.swift` |
| AI/analysis backends | Python 3 (`lib/chat_server.py`, `lib/stfu_core.py`, `lib/stfu_report.py`, `lib/ai_helper.py`) |
| Search index | Python 3 + SQLite FTS5 (`lib/search_index.py`) |
| UI shell | HTML/CSS/JS (`lib/theme.css`, `lib/ui.js`) — embedded in all module views |

---

## Build

```bash
# Build everything
make all

# Individual targets
make viewer-app       # Compile LFG.app
make menubar-app      # Compile LFG Helper.app (status bar agent)
make icons            # Generate AppIcon.icns from lfg-icon.svg
make clean            # Remove build artifacts

# Manual compilation
swiftc -O -o viewer viewer.swift -framework Cocoa -framework WebKit -framework Security
swiftc -O -o lfg-menubar menubar.swift -framework Cocoa -framework WebKit \
  -framework UserNotifications -framework Security -framework ServiceManagement
```

Requirements: macOS 13.0+, Swift toolchain, Python 3, `rsvg-convert` (for icon generation)

---

## Installation

```bash
# Run directly
~/tools/@yj/lfg/lfg [command]

# Or symlink to ~/bin
ln -sf ~/tools/@yj/lfg/lfg ~/bin/lfg
```

---

## Commands

| Command | Description |
|---------|-------------|
| `lfg` | Splash screen with disk stats and module status |
| `lfg wtfs [path]` | Disk usage analysis |
| `lfg dtf [--force] [--only <name>] [--docker] [--sudo]` | Cache cleanup |
| `lfg btau [status\|mount\|sync\|verify]` | Backup operations |
| `lfg devdrive [cmd] [--profile=NAME]` | Volume management |
| `lfg stfu [cmd]` | Source tree forensics |
| `lfg chat [send "message"]` | AI chat |
| `lfg search <query>` | Semantic search |
| `lfg dashboard` | Combined module dashboard |
| `lfg settings [show\|get\|set]` | Settings management |
| `lfg helper` | Launch LFG Helper (menubar agent) |

---

## Configuration

| File | Purpose |
|------|---------|
| `~/.config/lfg/settings.yaml` | Scan paths, module access, volume profiles, AI backend, theme |
| `~/.config/lfg/state.json` | Live module status (watched by menubar) |
| `~/.config/lfg/ai.yaml` | AI model configuration |
| `~/.config/lfg/helper_state.json` | Menubar agent persistent state |

---

## LFG.app — Viewer

Native WebKit viewer with full LFG UI.

- **JS → Swift bridge**: `window.webkit.messageHandlers.lfg.postMessage({action, ...})`
- **Actions**: `navigate`, `run`, `badge`, `quit`, `home`, `settings`, `keychain`
- **Dock badge**: Unread notification count via `NSApp.dockTile.badgeLabel`
- **Dock menu**: Quick-launch shortcuts for all modules
- **Keychain**: Stores AI API keys under `io.pegues.yj-tools.lfg`
- **Find-in-page**: Cmd+F overlay, Esc to dismiss
- **System appearance**: Observes light/dark mode, sets `data-system-theme` on `<html>`
- **Cache resolution**: Reads `volume_profiles` from `settings.yaml`, uses first mounted profile's `.lfg-cache/`
- **Bundle ID**: `io.pegues.yj-tools.lfg`

---

## LFG Helper — Menubar Agent

Proactive monitoring agent in the macOS status bar.

### Monitors

| Monitor | Trigger | Default Thresholds |
|---------|---------|-------------------|
| `disk` | Disk usage % | warn 80%, critical 90%, emergency 95% |
| `backup_staleness` | Days since last backup | warn 7d, critical 30d |
| `cache_growth` | Reclaimable cache size | warn 10 GB |
| `volume_health` | Volume mount status | unmounted = alert |

Configure via `settings.yaml` `helper:` section. Supports quiet hours, per-check cooldowns, and pause/resume toggle.

- **Disk graph**: 24-point history rendered as NSImage template
- **Launch at Login**: `SMAppService.mainApp` (native, macOS 13+)
- **IPC**: `DistributedNotificationCenter` (`com.lfg.viewer.*`, `com.lfg.menubar.*`)
- **Bundle ID**: `io.pegues.yj-tools.lfg.menubar`

---

## UI Themes

Toggle via `state.json` key `theme`:

- **`default`** — Dark opaque (#141418 background)
- **`glass`** — Liquid Glass: `backdrop-filter: blur(24px) saturate(180%)`, semi-transparent surfaces

---

## Identity

| Asset | Path |
|-------|------|
| LFG wordmark | `assets/brand/lfg-wordmark.svg` |
| App icon source | `assets/brand/lfg-icon.svg` |
| Compiled icon | `assets/brand/AppIcon.icns` |
| Module wordmarks | `assets/brand/{wtfs,dtf,btau,devdrive,stfu,ai}-wordmark.svg` |

### Agent Colors

| Agent | Color |
|-------|-------|
| Router / WTFS | `#4a9eff` blue |
| DTF | `#ff8c42` orange |
| BTAU | `#06d6a0` green |
| DEVDRIVE | `#c084fc` purple |
| STFU | `#e879f9` magenta |
| AI cache category | `#818cf8` indigo |

---

## Architecture

### Cache Layer
All modules write HTML output to `$LFG_CACHE_DIR`, resolved by `lib/state.sh`:
1. Iterates `volume_profiles` from `settings.yaml`
2. Uses first mounted profile's `/Volumes/<name>/.lfg-cache/`
3. Fallback: `$LFG_DIR`

### Volume Profiles
Defined in `settings.yaml` under `volume_profiles:`. Each profile:
- `name` — Volume directory name (e.g., `900DEVELOPER`)
- `purpose` — Human description
- `system_link` — Symlink target on system drive
- `file_patterns` — Glob patterns
- `color` — UI accent hex
- `auto_move_policy` — `largest_to_freest` | `manual` | `disabled`

### IPC
- **JS → Swift**: `window.webkit.messageHandlers.lfg.postMessage()`
- **Menubar ↔ Viewer**: `DistributedNotificationCenter`
- **Chat server**: HTTP on `localhost:3033`

### Module State
All modules source `lib/state.sh` to write progress to `~/.config/lfg/state.json`. The menubar watches this file via `DispatchSource` for live updates.

---

## Version Matrix

| Component | File(s) |
|-----------|---------|
| LFG Platform 2.4.0 | `lfg`, `lib/ui.js`, `lib/theme.css` |
| LFG.app 2.4.0 | `Info.plist` |
| LFG Helper.app 2.4.0 | `InfoMenubar.plist` |
| WTFS 2.4.0 | `lib/scan.sh` |
| DTF 2.4.0 | `lib/clean.sh` |
| BTAU 2.4.0 | `lib/btau.sh` |
| DEVDRIVE 2.4.0 | `lib/devdrive.sh` |
| STFU 2.4.0 | `lib/stfu.sh`, `lib/stfu_report.py` |
| Dashboard 2.4.0 | `lib/dashboard.sh` |
| Splash 2.4.0 | `lib/splash.sh` |
| Chat 2.4.0 | `lib/chat.sh`, `lib/chat_server.py` |

---

## Skill & Integration

- **Claude Code skill**: `~/.claude/commands/lfg.md`
- **CCEM APM bridge**: `~/Developer/ccem/apm/bridges/lfg-devdrive.json`
- **Plane PM**: Project `6bc05edb-a2b4-44c1-9cfc-2c938edb38a3`
- **GitHub PR**: https://github.com/peguesj/yj_tools/pull/4

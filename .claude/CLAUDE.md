# LFG - Local File Guardian v2.4.0

## Project Overview

- **Name**: LFG - Local File Guardian
- **Version**: 2.4.0
- **Working Directory**: `~/tools/@yj/lfg`
- **Type**: macOS disk management tool suite with WebKit UI, menubar agent, and AI chat

## Modules

### WTFS - Where's The Free Space
Disk usage analyzer that scans directories and presents storage breakdown via WebKit viewer.

### DTF - Delete Temp Files
Cache scanner and cleaner that identifies and removes temporary/cache files across common application directories.

### BTAU - Back That App Up
Backup manager for application data using sparse images, incremental sync, and integrity verification.

### DEVDRIVE - Developer Drive
Developer-focused volume management for mounting, unmounting, syncing, and verifying developer drives. Supports APFS volume operations with integrity verification and symlink forest management.

**Commands**: `mount`, `unmount`, `sync`, `verify`, `status`, `create`, `config`, `auto-move`

### STFU - Source Tree Forensics & Unification
Code forensics engine for duplicate detection, dependency analysis, project relationship mapping, library extraction candidates, and merge feasibility checks.

**Commands**: `deps`, `fingerprint`, `duplicates`, `libraries`, `envs`, `merge-check`, `scaffold`, `archive`

### Chat - AI Chat Interface
Multi-backend AI chat with agent routing (Router, WTFS, DTF, BTAU, DEVDRIVE, STFU specialists). SSE streaming, conversation history, semantic search integration.

**Server**: `python3 lib/chat_server.py` on port 3033
**Backends**: Ollama (default), LiteLLM, Claude API

### Search - Semantic Search
Full-text search across projects, filesystem, and history with SQLite FTS5.

**Commands**: `search <query>`, `search index`, `search update`

## Stack

- **Bash** - Core dispatcher (`lfg`) and module scripts
- **Swift (AppKit/WebKit)** - Native macOS components:
  - `viewer.swift` - WebKit viewer app with JS-to-native bridge, dock badge/menu, Keychain, find-in-page
  - `menubar.swift` - LFG Helper: NSStatusBar agent with proactive monitors, disk graph, launch-at-login, Keychain
- **Python3** - HTML templating, AI chat server, search indexer, STFU forensics
- **HTML/CSS/JS** - WebKit-rendered UI views with shared theme and component library

## Key Paths

| Component | Path |
|-----------|------|
| Dispatcher | `~/tools/@yj/lfg/lfg` |
| Modules | `~/tools/@yj/lfg/lib/{scan,clean,btau,devdrive,stfu,splash,dashboard,chat,search}.sh` |
| Cache HTML | `$LFG_CACHE_DIR` → first mounted volume profile's `.lfg-cache/` (fallback: `~/tools/@yj/lfg/`) |
| State | `~/.config/lfg/state.json` |
| Settings | `~/.config/lfg/settings.yaml` |
| AI Config | `~/.config/lfg/ai.yaml` |
| Swift sources | `~/tools/@yj/lfg/{viewer,menubar}.swift` |
| Theme | `~/tools/@yj/lfg/lib/theme.css` |
| UI JS | `~/tools/@yj/lfg/lib/ui.js` |
| Chat server | `~/tools/@yj/lfg/lib/chat_server.py` |
| Brand assets | `~/tools/@yj/lfg/assets/brand/{lfg-wordmark.svg,lfg-brandmark.svg,lfg-icon.svg,AppIcon.icns}` |
| Build system | `~/tools/@yj/lfg/Makefile` |
| Symlinks | `~/bin/{lfg,wtfs,dtf}` |

## Build Commands

```bash
# Build everything (viewer app + menubar app + icons)
make all

# Individual targets
make viewer-app       # Compile LFG.app (WebKit viewer)
make menubar-app      # Compile LFG Helper.app (status bar agent)
make icons            # Generate AppIcon.icns from lfg-icon.svg
make clean            # Remove build artifacts

# Manual compilation (without Makefile)
swiftc -O -o viewer viewer.swift -framework Cocoa -framework WebKit -framework Security
swiftc -O -o lfg-menubar menubar.swift -framework Cocoa -framework WebKit -framework UserNotifications -framework Security -framework ServiceManagement
```

## Version Matrix

| Component | Version | File(s) |
|-----------|---------|---------|
| LFG Platform | 2.4.0 | `lfg` (LFG_VERSION), `lib/ui.js`, `lib/theme.css` |
| LFG.app (Viewer) | 2.4.0 | `Info.plist` (CFBundleVersion) |
| LFG Helper.app | 2.4.0 | `InfoMenubar.plist` (CFBundleVersion) |
| WTFS module | 2.4.0 | `lib/scan.sh` (moduleVersion) |
| DTF module | 2.4.0 | `lib/clean.sh` (moduleVersion) |
| BTAU module | 2.4.0 | `lib/btau.sh` (moduleVersion) |
| DEVDRIVE module | 2.4.0 | `lib/devdrive.sh` (moduleVersion) |
| STFU module | 2.4.0 | `lib/stfu_report.py` (moduleVersion) |
| Dashboard | 2.4.0 | `lib/dashboard.sh` (moduleVersion) |
| Splash | 2.4.0 | `lib/splash.sh` (moduleVersion) |
| Chat | 2.4.0 | `lib/chat.sh` (moduleVersion), `lib/chat_server.py` |

## Skill Command Reference

LFG is registered as a Claude Code skill at `~/.claude/commands/lfg.md`.

| Subcommand | Description | Example |
|------------|-------------|---------|
| `/lfg scan [path]` | WTFS disk usage analysis | `/lfg scan ~/Developer` |
| `/lfg clean [--force]` | DTF cache cleanup (default: dry run) | `/lfg clean --force` |
| `/lfg backup [cmd]` | BTAU backup operations | `/lfg backup status` |
| `/lfg devdrive [cmd]` | DEVDRIVE volume management | `/lfg devdrive mount` |
| `/lfg stfu [cmd]` | STFU source tree forensics | `/lfg stfu deps` |
| `/lfg chat [send]` | AI chat interface | `/lfg chat send "check space"` |
| `/lfg search <query>` | Semantic search | `/lfg search "docker"` |
| `/lfg dashboard` | Combined dashboard | `/lfg dashboard` |
| `/lfg settings [cmd]` | Settings management | `/lfg settings show` |
| `/lfg helper` | Launch LFG Helper (menubar monitor) | `/lfg helper` |
| `lfg` (no args) | Splash screen | `lfg` |

## Agent Squadron

5 specialized agents available in `~/.claude/agents/lfg/`:

| Agent | Purpose |
|-------|---------|
| `lfg-scan` | Disk usage analysis - runs WTFS scans, interprets results, recommends cleanup targets |
| `lfg-clean` | Cache cleanup - runs DTF discovery, categorizes caches, executes cleanup with safety checks |
| `lfg-backup` | Backup management - runs BTAU discovery, schedules backups, manages restore operations |
| `lfg-devdrive` | Developer drive management - mount/unmount/sync/verify operations with integrity checks |
| `lfg-monitor` | System monitoring - watches disk usage, state changes, alerts on thresholds |

## Identity & Branding

### LFG Wordmark
The primary identity is the **LFG wordmark** -- geometric monospace-feel letterforms where "L", "F", "G" are constructed from stroked line segments with accent blue (#4a9eff) details.

- **SVG source**: `assets/brand/lfg-wordmark.svg` (200x64 viewBox)
- **App icon**: `assets/brand/lfg-icon.svg` (wordmark on dark rounded-rect, 512x512)
- **Menubar**: Bold "LFG" text rendered as NSImage template (auto light/dark)
- **Chat badges**: White "LFG" + agent-colored module label (e.g., "LFG STFU" in purple)
- **Brandmark**: `assets/brand/lfg-brandmark.svg` (shield + platter, legacy)

### Agent Colors
| Agent | Color |
|-------|-------|
| Router | `#4a9eff` (blue) |
| WTFS | `#4a9eff` (blue) |
| DTF | `#ff8c42` (orange) |
| BTAU | `#06d6a0` (green) |
| DEVDRIVE | `#c084fc` (purple) |
| STFU | `#e879f9` (magenta) |

## Integration

- **CCEM APM Bridge**: `~/Developer/ccem/apm/bridges/lfg-devdrive.json`
- **Claude Code Skill**: `~/.claude/commands/lfg.md`
- **Reference Registry**: `~/.claude/config/reference-registry.json`
- **Slash Commands**: `~/.claude/config/slash-commands.json` (registered as `/lfg`)
- **Plane PM**: Project ID `6bc05edb-a2b4-44c1-9cfc-2c938edb38a3`
- **PR**: https://github.com/peguesj/yj_tools/pull/4

## UI Themes

LFG supports two themes toggled via `state.json` key `theme` (`"default"` or `"glass"`):

- **Default**: Dark opaque theme (#141418 bg, solid surfaces)
- **Liquid Glass**: Apple-inspired glassmorphism with backdrop-filter blur, semi-transparent surfaces, specular highlights, and refraction effects

### Liquid Glass CSS Pattern

```css
.glass {
  background: rgba(255, 255, 255, 0.08);
  backdrop-filter: blur(24px) saturate(180%);
  -webkit-backdrop-filter: blur(24px) saturate(180%);
  border: 1px solid rgba(255, 255, 255, 0.12);
  border-radius: 1.25rem;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.3),
              inset 0 1px 0 rgba(255, 255, 255, 0.1);
}
```

## Dependency Map

**Authoritative source**: `.claude/dependency-map.json` - comprehensive dependency graph mapping all scripts, Swift apps, Python modules, state files, IPC channels, and external dependencies. Updated at v2.4.0.

- **High fan-in**: `state.sh` (9 dependents), `settings.sh` (6), `theme.css`/`ui.js` (8 each)
- **High fan-out**: `lfg` dispatcher (17 deps), `dashboard.sh` (8), `devdrive.sh` (8)
- **No circular dependencies** detected
- **Bundle IDs**: `io.pegues.yj-tools.lfg` (viewer), `io.pegues.yj-tools.lfg.menubar` (menubar)

## Architecture

### DevDrive Cache Layer
All module scripts write HTML output to `$LFG_CACHE_DIR`, resolved by `lib/state.sh`:
- Iterates `volume_profiles` from `settings.yaml`, uses first mounted profile's `/Volumes/<name>/.lfg-cache/`
- Fallback: `$LFG_DIR` (backward compatible)

### Volume Profiles
Multi-volume architecture defined in `~/.config/lfg/settings.yaml` under `volume_profiles:`. Each profile declares:
- `name`: Volume directory name (e.g., `900DEVELOPER`, `901LOGIC`)
- `purpose`: Human description
- `system_link`: Where it symlinks on system drive (e.g., `~/Developer`)
- `file_patterns`: Glob patterns to match (e.g., `*.logicx`)
- `color`: Hex color for UI accent
- `auto_move_policy`: `largest_to_freest` | `manual` | `disabled`

DevDrive commands accept `--profile=NAME` to target specific profiles. Auto-move with `largest_to_freest` policy moves largest projects from `system_link` to the mounted volume with most free space, skipping in-use directories (detected via `lsof`). In-use projects trigger notification prompts via `~/.config/lfg/prompts/` watched by the menubar app.

### IPC
- **JS → Swift**: `window.webkit.messageHandlers.lfg.postMessage()` (navigate, run, badge, quit, home, settings)
- **Menubar ↔ Viewer**: `DistributedNotificationCenter` (`com.lfg.viewer.*`, `com.lfg.menubar.*`)
- **Chat**: HTTP on localhost:3033 (POST /chat, GET /health, GET /history, POST /search)

### LFG Helper (Proactive Monitors)
The menubar agent includes a `HelperMonitor` engine that runs configurable checks at intervals. Configuration via `settings.yaml` `helper:` section:

| Monitor | Module Color | What It Checks | Default Thresholds |
|---------|-------------|----------------|-------------------|
| `disk` | WTFS blue | Disk usage % | warn 80%, critical 90%, emergency 95% |
| `backup_staleness` | BTAU green | Days since last cleanup | warn 7d, critical 30d |
| `cache_growth` | DTF orange | Reclaimable cache from DTF scan | warn 10GB |
| `volume_health` | DEVDRIVE purple | Volume mount status | unmounted = alert |

Features: quiet hours, per-check cooldowns, pause/resume toggle, persistent state in `~/.config/lfg/helper_state.json`.

### Dock Badge & Dock Menu
`viewer.swift` handles `badge` action from JS bridge, sets `NSApp.dockTile.badgeLabel`. The `ui.js` notifications system posts unread count via webkit message handler. The Dock menu provides quick-launch shortcuts for all modules and settings.

### Keychain Integration
Both apps use macOS Keychain (`Security.framework`) under service `io.pegues.yj-tools.lfg` for storing sensitive data (AI API keys). The viewer exposes Keychain ops to JS via `{action:"keychain", op:"get|set|delete", key:"...", value:"..."}` bridge messages.

### Launch at Login
LFG Helper uses `SMAppService.mainApp` (macOS 13+, `ServiceManagement.framework`) for a native Launch at Login toggle in its menu. No LaunchAgent plist required.

### Find in Page
Viewer supports Cmd+F find via a JS-injected overlay bar using `window.find()`. Esc or the close button dismisses it.

### System Appearance
Viewer observes `AppleInterfaceThemeChangedNotification` and sets `data-system-theme="dark|light"` on `document.documentElement`, allowing CSS/JS to respond to system light/dark mode changes.

## Development Rules

- **Agent replacement policy**: When a subagent's output file is updated, close the existing agent and spawn a new one rather than resuming the old one.
- **Version updates**: When bumping versions, update ALL files listed in the Version Matrix above.

## Patterns

- Modules source `lib/state.sh` for status tracking and `LFG_CACHE_DIR`
- HTML generated via `python3` (not sed) for safe multi-line templating
- WebKit viewer uses `WKScriptMessageHandler` for JS-to-native bridge
- Cross-module chaining via temp file polling
- Menubar watches `~/.config/lfg/state.json` via `DispatchSource`
- Chat agent routing: Router classifies intent, delegates to specialist via `[DELEGATE:XXX]` protocol (stripped before display)
- LFG wordmark used consistently for all identity: menubar icon, app icon, chat agent badges

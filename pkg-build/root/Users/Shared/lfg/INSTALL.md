# LFG v2.4.0 Installation Guide

## System Requirements

- macOS 13.0 (Ventura) or later
- Python 3.8+
- Xcode Command Line Tools (`xcode-select --install`)
- Swift 5.10+ (included with Xcode CLT)
- 50MB free disk space

## Quick Install (Installer Package)

```bash
sudo installer -pkg dist/LFG-2.4.0-installer.pkg -target /
```

The installer deploys the following:

| Path | Contents |
|------|----------|
| `/Users/Shared/lfg/` | Application files (full suite) |
| `/usr/local/bin/lfg` | CLI wrapper (exec into `/Users/Shared/lfg/lfg`) |
| `~/Library/LaunchAgents/io.lfg.helper.plist` | Menubar helper (KeepAlive) |
| `~/Library/LaunchAgents/io.lfg.inbox-watcher.plist` | Inbox watcher daemon (KeepAlive) |
| `~/Library/LaunchAgents/io.lfg.devdrive-automount.plist` | Volume automount at login (RunAtLoad, one-shot) |

The postinstall script automatically:

1. Detects the logged-in user (even when run as root via `sudo`)
2. Copies and patches LaunchAgent plists with correct `$HOME` paths
3. Loads all three LaunchAgents via `launchctl load`
4. Creates the `/usr/local/bin/lfg` symlink
5. Runs `lfg devdrive setup` to configure Finder icons, sidebar entries, and Quick Actions

### Building the .pkg from source

```bash
cd /Users/Shared/lfg
make pkg
# Output: dist/LFG-2.4.0-installer.pkg
```

Requires `pkgbuild`, `productbuild`, and `rsync` (all included with Xcode CLT).

## Manual Install (Developer)

```bash
git clone <repo> /Users/Shared/lfg
cd /Users/Shared/lfg
make all
ln -sf $(pwd)/lfg /usr/local/bin/lfg
lfg devdrive setup
```

`make all` builds two Swift app bundles:

- **LFG.app** -- WebKit-based viewer/dashboard (Cocoa, WebKit, Security frameworks)
- **LFG Helper.app** -- Menubar monitor (Cocoa, WebKit, UserNotifications, Security, ServiceManagement)

To install LaunchAgents manually, copy the three plist files to `~/Library/LaunchAgents/` and load them:

```bash
cp io.lfg.helper.plist io.lfg.inbox-watcher.plist io.lfg.devdrive-automount.plist \
   ~/Library/LaunchAgents/

launchctl load ~/Library/LaunchAgents/io.lfg.helper.plist
launchctl load ~/Library/LaunchAgents/io.lfg.inbox-watcher.plist
launchctl load ~/Library/LaunchAgents/io.lfg.devdrive-automount.plist
```

Note: The plist files in the repo use `/Users/Shared/lfg` as the base path. If your install path differs, update `ProgramArguments` and `EnvironmentVariables` accordingly.

## Post-Install Verification

Run through this checklist after installation:

```bash
# Version check
lfg --version
# Expected: lfg v2.4.0

# Help output (all modules listed)
lfg --help

# LaunchAgents running (should show 3 agents)
launchctl list | grep lfg
# Expected:
#   -   0   io.lfg.devdrive-automount
#   <pid>   0   io.lfg.helper
#   <pid>   0   io.lfg.inbox-watcher

# Finder sidebar shows DDRV volumes
ls /Volumes/DDRV*

# Right-click context menu shows LFG Quick Actions
# (Verify in Finder: right-click any folder)

# Spotlight manager status
lfg ssd

# Developer volume status
lfg devdrive
```

## Modules

| Module | Command | Description |
|--------|---------|-------------|
| **WTFS** | `lfg wtfs [path]` | Where's The Free Space -- disk usage scanner for configured paths |
| **DTF** | `lfg dtf [--force]` | Delete Temp Files -- cache cleaner with dry-run default |
| **BTAU** | `lfg btau [cmd]` | Back That App Up -- sparse image backup manager |
| **DEVDRIVE** | `lfg devdrive [cmd]` | Developer Drive -- volume manager with Finder integration, sidebar entries, Quick Actions, and automount |
| **SSD** | `lfg ssd [cmd]` | Slows Sh\*t Down -- Spotlight/mds indexing manager for external and CloudStorage volumes |
| **STFU** | `lfg stfu [cmd]` | Source Tree Forensics Utility -- project forensics, dependency analysis, duplicate detection, merge checks |
| **AI** | `lfg ai [cmd]` | AI-powered analysis and model configuration |
| **Chat** | `lfg chat [msg]` | AI chat interface |
| **Search** | `lfg search <query>` | Semantic search across projects, files, and history |
| **Settings** | `lfg settings [cmd]` | Configuration manager for paths, module permissions, and defaults |
| **Dashboard** | `lfg dashboard` | Combined overview of all modules |
| **Helper** | `lfg helper` | Menubar monitor (LFG Helper.app) |
| **Inbox** | `lfg inbox [cmd]` | Message inbox with watcher daemon |

## LaunchAgent Management

LFG installs three LaunchAgents in `~/Library/LaunchAgents/`:

| Agent | Label | Behavior |
|-------|-------|----------|
| Menubar Helper | `io.lfg.helper` | KeepAlive (restarts unless clean exit), ThrottleInterval 10s |
| Inbox Watcher | `io.lfg.inbox-watcher` | KeepAlive (restarts unless clean exit), ThrottleInterval 10s, 5s poll |
| DevDrive Automount | `io.lfg.devdrive-automount` | RunAtLoad one-shot, mounts DDRV/YJ_MORE sparse images at login |

### Commands

```bash
# List running agents
launchctl list | grep lfg

# Stop an agent
launchctl unload ~/Library/LaunchAgents/io.lfg.<name>.plist

# Start an agent
launchctl load ~/Library/LaunchAgents/io.lfg.<name>.plist

# Reload after editing a plist
launchctl unload ~/Library/LaunchAgents/io.lfg.<name>.plist
launchctl load ~/Library/LaunchAgents/io.lfg.<name>.plist
```

### Log Locations

| Agent | stdout | stderr |
|-------|--------|--------|
| Helper | `~/.config/lfg/helper.log` | `~/.config/lfg/helper.err` |
| Inbox Watcher | `~/.config/lfg/inbox/watcher-stdout.log` | `~/.config/lfg/inbox/watcher-stderr.log` |
| Automount | `~/.config/lfg/automount.log` | `~/.config/lfg/automount-err.log` |

## Uninstallation

```bash
# 1. Stop all LaunchAgents
launchctl unload ~/Library/LaunchAgents/io.lfg.helper.plist
launchctl unload ~/Library/LaunchAgents/io.lfg.inbox-watcher.plist
launchctl unload ~/Library/LaunchAgents/io.lfg.devdrive-automount.plist

# 2. Remove LaunchAgent plists
rm -f ~/Library/LaunchAgents/io.lfg.*.plist

# 3. Remove application files
sudo rm -rf /Users/Shared/lfg

# 4. Remove CLI symlink
sudo rm -f /usr/local/bin/lfg

# 5. Remove Quick Action workflows
rm -rf ~/Library/Services/LFG*.workflow

# 6. Remove config and logs
rm -rf ~/.config/lfg
```

If installed via the developer (manual) method, also remove the source directory and any personal symlinks.

## Troubleshooting

### Viewer not opening

The LFG.app bundle must be compiled before first use. The dispatcher auto-builds when needed, but you can force a rebuild:

```bash
make -C /Users/Shared/lfg LFG.app
```

### LaunchAgent not loading

Check for bootstrap errors:

```bash
launchctl load ~/Library/LaunchAgents/io.lfg.helper.plist 2>&1
```

Common causes: malformed plist XML, incorrect `ProgramArguments` paths, missing executable. Validate with:

```bash
plutil -lint ~/Library/LaunchAgents/io.lfg.helper.plist
```

### Volumes not automounting

The automount agent searches `~/.config/btau`, `~/.config/lfg/images`, and `/Volumes/*/btau` for `.sparseimage`, `.sparsebundle`, and `.dmg` files matching known volume names (DDRV900-904, YJ_MORE). Verify:

```bash
# Check the automount log
cat ~/.config/lfg/automount.log

# Manually test mounting
hdiutil attach ~/.config/btau/DDRV900.sparseimage -mountpoint /Volumes/DDRV900 -noverify
```

### Quick Actions missing

Re-run the DevDrive setup to reinstall Finder integration (sidebar, icons, Quick Actions):

```bash
lfg devdrive setup
```

### Menubar helper not showing

Start the helper manually:

```bash
lfg helper
```

This builds `LFG Helper.app` if needed and launches it in the background. The LaunchAgent will keep it alive across logouts.

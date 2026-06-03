#!/usr/bin/env bash
# devdrive-rsync-mirror.sh — Active rsync mirror for sparseimage volumes.
#
# Maintains a local fallback copy of critical sparseimage data so that:
#   1. When a sparseimage is restored/recreated, the local mirror repopulates it.
#   2. Concurrent sessions that don't have the volume mounted can still read data.
#   3. No data loss when a sparseimage is detached, corrupted, or replaced.
#
# Two modes:
#   --sync-now   One-shot bidirectional sync (volume → fallback, then fallback → volume newer files only)
#   --watch      Daemon mode: poll every POLL_INTERVAL, sync on change.
#   --restore <volume>  Restore from fallback after sparseimage is recreated.
#
# Mirrored paths (configurable via FALLBACK_MAP):
#   /Volumes/DDRV-904-MEMVT/claude-tasks  ↔  ~/DevDrive/904MEMVT-fallback/claude-tasks
#   /Volumes/903LUME/projects             ↔  ~/DevDrive/903CLAUD-fallback/projects
#   /Volumes/903LUME/tasks                ↔  ~/DevDrive/903CLAUD-fallback/tasks
#
# State file: ~/.config/lfg/rsync-mirror-state.json
# Log file:   ~/.config/lfg/rsync-mirror.log

set -uo pipefail

LOG="$HOME/.config/lfg/rsync-mirror.log"
STATE="$HOME/.config/lfg/rsync-mirror-state.json"
PID_FILE="$HOME/.config/lfg/rsync-mirror.pid"
APM="http://localhost:3032"
POLL_INTERVAL=300  # 5 minutes
mkdir -p "$(dirname "$LOG")"

# volume_path|fallback_path|priority(volume_authoritative=v, fallback_authoritative=f, newer_wins=n)
MIRRORS=(
  "/Volumes/DDRV-904-MEMVT/claude-tasks|$HOME/DevDrive/904MEMVT-fallback/claude-tasks|n"
  "/Volumes/903LUME/projects|$HOME/DevDrive/903CLAUD-fallback/projects|n"
  "/Volumes/903LUME/tasks|$HOME/DevDrive/903CLAUD-fallback/tasks|n"
  "/Volumes/903LUME/claude-projects|$HOME/DevDrive/.claude-projects-fallback|n"
)

ts()  { date "+%Y-%m-%dT%H:%M:%S"; }
log() { echo "[$(ts)] $*" >> "$LOG"; echo "[$(ts)] $*"; }

apm_notify() {
  local type="$1" title="$2" msg="$3"
  curl -s -X POST "$APM/api/notify" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"$type\",\"title\":\"$title\",\"message\":\"$msg\",\"category\":\"rsync-mirror\"}" \
    >/dev/null 2>&1 || true
}

sync_pair() {
  local vol="$1" fb="$2" priority="${3:-n}"

  if [ ! -d "$vol" ]; then
    log "SKIP: $vol not mounted"
    return 0
  fi

  mkdir -p "$fb"

  case "$priority" in
    v)  # Volume is authoritative
        rsync -a --delete "$vol/" "$fb/" 2>&1 | tail -3 | while read -r l; do log "  $l"; done
        log "MIRROR: $vol → $fb (volume authoritative)"
        ;;
    f)  # Fallback is authoritative (used during volume restore)
        rsync -a --delete "$fb/" "$vol/" 2>&1 | tail -3 | while read -r l; do log "  $l"; done
        log "MIRROR: $fb → $vol (fallback authoritative)"
        ;;
    n|*)  # Newer-wins bidirectional (safe default)
        rsync -au "$vol/" "$fb/" 2>&1 | tail -3 | while read -r l; do log "  $l"; done
        rsync -au "$fb/" "$vol/" 2>&1 | tail -3 | while read -r l; do log "  $l"; done
        log "MIRROR: $vol ↔ $fb (newer-wins)"
        ;;
  esac
}

cmd_sync_now() {
  log "=== sync-now starting (${#MIRRORS[@]} pairs) ==="
  for pair in "${MIRRORS[@]}"; do
    IFS='|' read -r vol fb priority <<< "$pair"
    sync_pair "$vol" "$fb" "$priority"
  done
  log "=== sync-now done ==="
}

cmd_restore() {
  local target="$1"
  log "=== restore: $target ==="
  for pair in "${MIRRORS[@]}"; do
    IFS='|' read -r vol fb priority <<< "$pair"
    if [[ "$vol" == "$target"* ]]; then
      log "Restoring $vol from $fb"
      sync_pair "$vol" "$fb" "f"
      apm_notify "info" "Sparseimage Restored" "$vol repopulated from $fb"
    fi
  done
}

cmd_watch() {
  log "=== watch mode starting (interval=${POLL_INTERVAL}s) ==="
  echo $$ > "$PID_FILE"
  while true; do
    cmd_sync_now
    sleep "$POLL_INTERVAL"
  done
}

cmd_status() {
  echo "=== rsync mirror state ==="
  for pair in "${MIRRORS[@]}"; do
    IFS='|' read -r vol fb priority <<< "$pair"
    vol_status="○ unmounted"
    [ -d "$vol" ] && vol_status="● mounted"
    fb_status="○ missing"
    [ -d "$fb" ] && fb_status="● $(du -sh "$fb" 2>/dev/null | cut -f1)"
    echo "  [$priority] $vol_status $vol"
    echo "       $fb_status $fb"
  done
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo ""
    echo "Watcher running (pid $(cat "$PID_FILE"))"
  fi
}

case "${1:---sync-now}" in
  --sync-now|sync-now)  cmd_sync_now ;;
  --watch|watch)        cmd_watch ;;
  --restore|restore)    cmd_restore "${2:-}" ;;
  --status|status)      cmd_status ;;
  --stop|stop)          [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null && rm -f "$PID_FILE" && echo "stopped" ;;
  *) echo "Usage: $0 [--sync-now|--watch|--restore <volume>|--status|--stop]"; exit 1 ;;
esac

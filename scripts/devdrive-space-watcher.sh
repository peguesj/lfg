#!/usr/bin/env bash
# devdrive-space-watcher.sh — Continuous free-space monitor.
# Polls all mounted DDRV volumes + main system volume every POLL_INTERVAL seconds.
# When any volume drops below FREE_THRESHOLD_GB, migrates migratable data to YJ_MORE.
#
# Usage:
#   devdrive-space-watcher.sh [--daemon] [--interval <secs>] [--threshold <GB>] [--dry-run]
#
# Daemon mode: detach and write PID to ~/.config/lfg/space-watcher.pid

set -uo pipefail

SCRIPT_NAME="devdrive-space-watcher"
PID_FILE="$HOME/.config/lfg/space-watcher.pid"
LOG_FILE="$HOME/.config/lfg/space-watcher.log"
STATE_FILE="$HOME/.config/lfg/space-watcher-state.json"
OVERFLOW_VOLUME="/Volumes/YJ_MORE"
OVERFLOW_MIGRATION_DIR="$OVERFLOW_VOLUME/DevDrive/overflow"
FREE_THRESHOLD_GB=2
POLL_INTERVAL=60   # seconds
APM_URL="http://localhost:3032"

mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$PID_FILE")"

# Parse args
DAEMON=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --daemon)    DAEMON=true ;;
    --dry-run)   DRY_RUN=true ;;
    --interval=*) POLL_INTERVAL="${arg#*=}" ;;
    --threshold=*) FREE_THRESHOLD_GB="${arg#*=}" ;;
    --stop)
      if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        kill "$pid" 2>/dev/null && echo "Stopped watcher (pid $pid)" || echo "No process at pid $pid"
        rm -f "$PID_FILE"
      else
        echo "No PID file found at $PID_FILE"
      fi
      exit 0
      ;;
    --status)
      if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
          echo "Running (pid $pid)"
          [ -f "$LOG_FILE" ] && tail -5 "$LOG_FILE"
        else
          echo "PID file exists but process $pid is not running"
        fi
      else
        echo "Not running"
      fi
      exit 0
      ;;
  esac
done

if $DAEMON; then
  # Re-exec without --daemon in background
  nohup bash "$0" --interval="$POLL_INTERVAL" --threshold="$FREE_THRESHOLD_GB" \
    $( $DRY_RUN && echo "--dry-run" ) \
    >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  echo "[$SCRIPT_NAME] Daemon started (pid $(cat "$PID_FILE")). Log: $LOG_FILE"
  exit 0
fi

ts()  { date "+%Y-%m-%dT%H:%M:%S"; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; echo "[$(ts)] $*"; }

apm_notify() {
  local type="$1" title="$2" msg="$3"
  curl -s -X POST "$APM_URL/api/notify" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"$type\",\"title\":\"$title\",\"message\":\"$msg\",\"category\":\"devdrive\"}" \
    >/dev/null 2>&1 || true
}

free_gb() {
  local mp="$1"
  [ -d "$mp" ] || { echo "-1"; return; }
  df -k "$mp" 2>/dev/null | awk 'NR==2 {printf "%.2f", $4/1048576}'
}

migrate_to_overflow() {
  local volume="$1"
  local free="$2"

  log "  MIGRATE: $volume free=${free}GB < ${FREE_THRESHOLD_GB}GB → targeting $OVERFLOW_MIGRATION_DIR"

  [ -d "$OVERFLOW_VOLUME" ] || { log "  ERROR: $OVERFLOW_VOLUME not mounted, cannot migrate"; return 1; }

  local overflow_free
  overflow_free=$(free_gb "$OVERFLOW_VOLUME")
  if (( $(echo "$overflow_free < 5" | bc -l) )); then
    log "  ERROR: $OVERFLOW_VOLUME only has ${overflow_free}GB free — too low for migration"
    apm_notify "error" "DevDrive Overflow Full" "$OVERFLOW_VOLUME only ${overflow_free}GB free — cannot migrate from $volume"
    return 1
  fi

  # Build a label from the mount point for the destination subdir
  local vol_label
  vol_label=$(basename "$volume" | tr '/' '-')
  local dest_dir="$OVERFLOW_MIGRATION_DIR/$vol_label-$(date +%Y%m%d%H%M%S)"

  # Candidate paths to migrate (ordered by typical size, safest first):
  # 1. npm/pip cache directories
  # 2. Oban/DB dumps
  # 3. Large log archives
  local -a MIGRATE_CANDIDATES=(
    "$volume/.npm/_npx"
    "$volume/.npm/_cacache"
    "$volume/pip-cache"
    "$volume/tmp"
    "$volume/logs/archive"
  )

  if $DRY_RUN; then
    log "  DRY RUN: would create $dest_dir and migrate candidates:"
    for c in "${MIGRATE_CANDIDATES[@]}"; do
      [ -d "$c" ] && log "    $c ($(du -sh "$c" 2>/dev/null | cut -f1))"
    done
    return 0
  fi

  mkdir -p "$dest_dir"

  local moved_any=false
  for candidate in "${MIGRATE_CANDIDATES[@]}"; do
    if [ -d "$candidate" ]; then
      local size
      size=$(du -sh "$candidate" 2>/dev/null | cut -f1 || echo "?")
      log "  Moving $candidate ($size) → $dest_dir/"
      mv "$candidate" "$dest_dir/" && moved_any=true || log "  WARNING: mv failed for $candidate"
    fi
  done

  # Re-check free space after migration
  local new_free
  new_free=$(free_gb "$volume")
  log "  After migration: $volume free=${new_free}GB"

  if $moved_any; then
    apm_notify "info" "DevDrive Auto-Migrated" \
      "$volume was at ${free}GB free. Moved caches to $dest_dir. Now ${new_free}GB free."

    # Update state file
    python3 - <<PYEOF
import json, os, datetime
state_file = "$STATE_FILE"
state = {}
try:
    with open(state_file) as f: state = json.load(f)
except Exception: pass
state.setdefault("migrations", []).append({
    "ts": datetime.datetime.now().isoformat(),
    "volume": "$volume",
    "free_before_gb": $free,
    "free_after_gb": $new_free,
    "dest": "$dest_dir"
})
with open(state_file, 'w') as f: json.dump(state, f, indent=2)
PYEOF
  else
    log "  WARNING: no candidate directories found on $volume to migrate"
  fi
}

# Volumes to watch (checked in order; system volume last as it requires different strategy)
declare -a WATCH_VOLUMES=(
  "/Volumes/DDRV-900-HOOKS"
  "/Volumes/DDRV-901-DEVLIB"
  "/Volumes/DDRV-902-APMDR"
  "/Volumes/DDRV902"
  "/Volumes/DDRV-904-MEMVT"
  "/Volumes/devdrive"
  "/System/Volumes/Data"
)

log "=== $SCRIPT_NAME started (threshold=${FREE_THRESHOLD_GB}GB, interval=${POLL_INTERVAL}s, dry_run=$DRY_RUN) ==="

DEBOUNCE_DIR="$HOME/.config/lfg/space-watcher-debounce"
mkdir -p "$DEBOUNCE_DIR"

debounce_key() { echo "$1" | tr '/' '_'; }

last_migrated_ts() {
  local key
  key="$DEBOUNCE_DIR/$(debounce_key "$1")"
  [ -f "$key" ] && cat "$key" || echo "0"
}

set_migrated_ts() {
  echo "$(date +%s)" > "$DEBOUNCE_DIR/$(debounce_key "$1")"
}

while true; do
  for vol in "${WATCH_VOLUMES[@]}"; do
    [ -d "$vol" ] || continue

    free=$(free_gb "$vol")
    echo "$free" | grep -qE '^-' && continue

    if python3 -c "exit(0 if float('$free') < $FREE_THRESHOLD_GB else 1)" 2>/dev/null; then
      log "WARNING: $vol free=${free}GB < ${FREE_THRESHOLD_GB}GB threshold"

      now=$(date +%s)
      last=$(last_migrated_ts "$vol")
      elapsed=$(( now - last ))

      if [ "$elapsed" -gt 600 ]; then
        apm_notify "warn" "DevDrive Low Space" "$vol only ${free}GB free — initiating migration"
        migrate_to_overflow "$vol" "$free"
        set_migrated_ts "$vol"
      else
        log "  Skipping migration for $vol (last migrated ${elapsed}s ago)"
      fi
    fi
  done

  sleep "$POLL_INTERVAL"
done

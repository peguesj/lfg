#!/usr/bin/env bash
# btau_archive.sh - restic-on-sparsebundle archival workflow
# US-CCEM-482, ADR-001 D1
#
# Subcommands:
#   init         Create encrypted sparsebundle + store passphrase in Keychain
#   mount        Attach sparsebundle (refcounted via flock)
#   unmount      Detach sparsebundle (refcounted)
#   restic-init  Initialize restic repo inside the mounted bundle
#   archive DIR  restic backup --tag claude-code DIR
#   verify       restic check --read-data --read-data-subset=10%
#   status       Report mount + repo state
#
# Env:
#   LFG_BTAU_PATH  Path to sparsebundle (default: $HOME/DevDrive/btau-archive.sparsebundle)
#   LFG_BTAU_SIZE  Size cap in GB (default: 500)

set -uo pipefail

BTAU_PATH="${LFG_BTAU_PATH:-$HOME/DevDrive/btau-archive.sparsebundle}"
BTAU_SIZE_GB="${LFG_BTAU_SIZE:-500}"
BTAU_VOLNAME="btau-archive"
BTAU_KEYCHAIN_SERVICE="io.pegues.btau-archive"
BTAU_LOCKFILE="/tmp/btau-archive.lock"
BTAU_REFCOUNT="/tmp/btau-archive.refcount"
BTAU_MOUNTPOINT_FILE="/tmp/btau-archive.mountpoint"

log()  { printf '[btau-archive] %s\n' "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# --- Keychain helpers --------------------------------------------------------
kc_get_passphrase() {
    security find-generic-password -a "$USER" -s "$BTAU_KEYCHAIN_SERVICE" -w 2>/dev/null
}

kc_set_passphrase() {
    local pp="$1"
    security delete-generic-password -a "$USER" -s "$BTAU_KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
    security add-generic-password -a "$USER" -s "$BTAU_KEYCHAIN_SERVICE" -w "$pp" \
        || die "Failed to add passphrase to Keychain"
}

# --- Mount detection ---------------------------------------------------------
current_mountpoint() {
    # Returns mountpoint if attached, empty otherwise
    if [[ -f "$BTAU_MOUNTPOINT_FILE" ]]; then
        local mp
        mp="$(cat "$BTAU_MOUNTPOINT_FILE" 2>/dev/null)"
        if [[ -n "$mp" && -d "$mp" ]] && mount | grep -q " on $mp "; then
            printf '%s' "$mp"
            return 0
        fi
    fi
    # Fallback: probe hdiutil info
    hdiutil info 2>/dev/null | awk -v bp="$BTAU_PATH" '
        /^image-path/ && $0 ~ bp { found=1 }
        found && /\/Volumes\// { print $NF; exit }
    '
}

# --- Subcommands -------------------------------------------------------------
cmd_init() {
    if [[ -e "$BTAU_PATH" ]]; then
        log "Sparsebundle already exists at $BTAU_PATH (skipping create)"
    else
        log "Will create encrypted sparsebundle: $BTAU_PATH ($BTAU_SIZE_GB GB cap)"
        printf 'Enter passphrase for new btau-archive sparsebundle: '
        read -rs PP1; echo
        printf 'Confirm passphrase: '
        read -rs PP2; echo
        [[ "$PP1" == "$PP2" ]] || die "Passphrases do not match"
        [[ -n "$PP1" ]] || die "Passphrase cannot be empty"

        kc_set_passphrase "$PP1"
        log "Passphrase stored in Keychain (service=$BTAU_KEYCHAIN_SERVICE)"

        mkdir -p "$(dirname "$BTAU_PATH")"
        # NOTE: actual sparsebundle creation deferred — external SSD must be mounted.
        # When ready, run:
        #   printf '%s' "$PP1" | hdiutil create -encryption AES-256 -stdinpass \
        #     -size ${BTAU_SIZE_GB}g -type SPARSEBUNDLE -imagekey sparse-band-size=16384 \
        #     -fs APFS -volname "$BTAU_VOLNAME" "$BTAU_PATH"
        log "DEFERRED: hdiutil create not run (mount external SSD then re-run init with --create)"
        unset PP1 PP2
    fi
    log "init complete"
}

cmd_mount() {
    local mp
    mp="$(current_mountpoint)"
    if [[ -n "$mp" ]]; then
        # Already mounted -- bump refcount
        local n=0
        [[ -f "$BTAU_REFCOUNT" ]] && n="$(cat "$BTAU_REFCOUNT")"
        echo $((n + 1)) > "$BTAU_REFCOUNT"
        log "already mounted at $mp (refcount=$((n + 1)))"
        printf '%s\n' "$mp"
        return 0
    fi

    [[ -e "$BTAU_PATH" ]] || die "Sparsebundle not found: $BTAU_PATH (run init)"

    local pp
    pp="$(kc_get_passphrase)" || die "No passphrase in Keychain (service=$BTAU_KEYCHAIN_SERVICE)"

    (
        flock -x 200
        log "Attaching $BTAU_PATH..."
        local out
        out="$(printf '%s' "$pp" | hdiutil attach -stdinpass -nobrowse -mountrandom /tmp "$BTAU_PATH" 2>&1)" \
            || die "hdiutil attach failed: $out"
        mp="$(printf '%s\n' "$out" | awk '/\/tmp\// {print $NF; exit}')"
        [[ -n "$mp" ]] || die "Could not determine mountpoint from hdiutil output"
        printf '%s' "$mp" > "$BTAU_MOUNTPOINT_FILE"
        echo 1 > "$BTAU_REFCOUNT"
        log "mounted at $mp (refcount=1)"
        printf '%s\n' "$mp"
    ) 200>"$BTAU_LOCKFILE"
}

cmd_unmount() {
    local mp
    mp="$(current_mountpoint)"
    if [[ -z "$mp" ]]; then
        log "not mounted (noop)"
        rm -f "$BTAU_REFCOUNT" "$BTAU_MOUNTPOINT_FILE"
        return 0
    fi

    (
        flock -x 200
        local n=1
        [[ -f "$BTAU_REFCOUNT" ]] && n="$(cat "$BTAU_REFCOUNT")"
        n=$((n - 1))
        if [[ $n -gt 0 ]]; then
            echo "$n" > "$BTAU_REFCOUNT"
            log "refcount decremented to $n (still mounted at $mp)"
            return 0
        fi
        log "Detaching $mp..."
        hdiutil detach "$mp" || die "hdiutil detach failed for $mp"
        rm -f "$BTAU_REFCOUNT" "$BTAU_MOUNTPOINT_FILE"
        log "unmounted"
    ) 200>"$BTAU_LOCKFILE"
}

restic_env() {
    local mp="$1"
    local pp
    pp="$(kc_get_passphrase)" || die "No passphrase in Keychain"
    export RESTIC_REPOSITORY="$mp/restic"
    export RESTIC_PASSWORD="$pp"
}

cmd_restic_init() {
    command -v restic >/dev/null || die "restic not installed (brew install restic)"
    local mp
    mp="$(current_mountpoint)"
    [[ -n "$mp" ]] || die "Not mounted (run: btau_archive mount)"
    restic_env "$mp"
    if restic cat config >/dev/null 2>&1; then
        log "restic repo already initialized at $RESTIC_REPOSITORY"
        return 0
    fi
    log "Initializing restic repo at $RESTIC_REPOSITORY..."
    restic init || die "restic init failed"
    log "restic-init complete"
}

cmd_archive() {
    local src="${1:-}"
    [[ -n "$src" ]]    || die "Usage: btau_archive archive <source-dir>"
    [[ -d "$src" ]]    || die "Source not a directory: $src"
    command -v restic >/dev/null || die "restic not installed"

    local mp
    mp="$(current_mountpoint)"
    [[ -n "$mp" ]] || die "Not mounted (run: btau_archive mount)"
    restic_env "$mp"
    log "Archiving $src to $RESTIC_REPOSITORY..."
    restic backup --tag claude-code "$src" || die "restic backup failed"
    log "archive complete"
}

cmd_verify() {
    command -v restic >/dev/null || die "restic not installed"
    local mp
    mp="$(current_mountpoint)"
    [[ -n "$mp" ]] || die "Not mounted (run: btau_archive mount)"
    restic_env "$mp"
    log "Running restic check (10% read-data subset)..."
    restic check --read-data --read-data-subset=10% || die "restic check FAILED"
    log "verify OK"
}

cmd_status() {
    local mp
    mp="$(current_mountpoint)"
    printf 'btau-archive status\n'
    printf '  bundle:     %s %s\n' "$BTAU_PATH" \
        "$([[ -e "$BTAU_PATH" ]] && echo '[exists]' || echo '[MISSING]')"
    printf '  size cap:   %s GB\n' "$BTAU_SIZE_GB"
    printf '  keychain:   service=%s\n' "$BTAU_KEYCHAIN_SERVICE"
    if [[ -n "$mp" ]]; then
        local n=0
        [[ -f "$BTAU_REFCOUNT" ]] && n="$(cat "$BTAU_REFCOUNT")"
        printf '  mounted:    yes at %s (refcount=%s)\n' "$mp" "$n"
        if command -v restic >/dev/null 2>&1 && [[ -d "$mp/restic" ]]; then
            restic_env "$mp"
            printf '  repo:       %s\n' "$RESTIC_REPOSITORY"
            restic stats --mode raw-data 2>/dev/null | sed 's/^/    /' || printf '    (restic stats unavailable)\n'
        else
            printf '  repo:       (none / not initialized)\n'
        fi
    else
        printf '  mounted:    no\n'
    fi
}

usage() {
    sed -n '2,18p' "$0"
    exit 2
}

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        init)        cmd_init "$@" ;;
        mount)       cmd_mount "$@" ;;
        unmount)     cmd_unmount "$@" ;;
        restic-init) cmd_restic_init "$@" ;;
        archive)     cmd_archive "$@" ;;
        verify)      cmd_verify "$@" ;;
        status)      cmd_status "$@" ;;
        ""|-h|--help) usage ;;
        *)           die "Unknown subcommand: $cmd (try --help)" ;;
    esac
}

main "$@"

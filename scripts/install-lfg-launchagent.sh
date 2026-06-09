#!/usr/bin/env bash
# install-lfg-launchagent.sh
#
# Stages the v3 LFG menubar app for auto-launch at login via launchd.
#
# Copies io.lfg.app.plist to ~/Library/LaunchAgents/, bootstraps it into the
# current GUI session, and prints status. Idempotent — safe to re-run after
# upgrades.
#
# Usage:
#   bash scripts/install-lfg-launchagent.sh           # install + load
#   bash scripts/install-lfg-launchagent.sh --status  # show load state
#   bash scripts/install-lfg-launchagent.sh --uninstall  # bootout + remove

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_SRC="${REPO_ROOT}/io.lfg.app.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/io.lfg.app.plist"
LABEL="io.lfg.app"
DOMAIN="gui/$(id -u)"

case "${1:-install}" in
    --status)
        if launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
            echo "io.lfg.app: LOADED in ${DOMAIN}"
            launchctl print "${DOMAIN}/${LABEL}" | grep -E "state|path|pid" | head -5
        else
            echo "io.lfg.app: NOT LOADED"
        fi
        ;;

    --uninstall)
        echo "→ Booting out ${LABEL}…"
        launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
        rm -f "${PLIST_DST}"
        echo "✓ Uninstalled."
        ;;

    install|*)
        if [[ ! -f "${PLIST_SRC}" ]]; then
            echo "✗ Missing source plist: ${PLIST_SRC}" >&2
            exit 1
        fi

        if [[ ! -x "${REPO_ROOT}/LFG.app/Contents/MacOS/LFG" ]]; then
            echo "✗ LFG.app not built. Run: make lfg-app" >&2
            exit 1
        fi

        mkdir -p "${HOME}/Library/LaunchAgents"
        mkdir -p "${HOME}/.config/lfg"

        cp "${PLIST_SRC}" "${PLIST_DST}"
        echo "✓ Copied plist → ${PLIST_DST}"

        # Bootout existing (if any) before bootstrap, to pick up changes.
        launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true

        launchctl bootstrap "${DOMAIN}" "${PLIST_DST}"
        launchctl enable "${DOMAIN}/${LABEL}"
        launchctl kickstart -k "${DOMAIN}/${LABEL}"

        echo "✓ Bootstrapped ${LABEL} into ${DOMAIN}"
        echo ""
        echo "Verify with:"
        echo "  bash scripts/install-lfg-launchagent.sh --status"
        echo "  launchctl print ${DOMAIN}/${LABEL}"
        ;;
esac

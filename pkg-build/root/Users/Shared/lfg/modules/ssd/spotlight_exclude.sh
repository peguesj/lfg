#!/usr/bin/env bash
# SSD Module — Slows Sh*t Down: Spotlight Exclusion
# Legacy standalone runner — delegates to lib/ssd.sh for full state integration.
# Direct use: bash modules/ssd/spotlight_exclude.sh
# Preferred:  lfg ssd exclude [--force]
set -euo pipefail

LFG_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
exec bash "$LFG_DIR/lib/ssd.sh" exclude "$@"

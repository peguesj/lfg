#!/usr/bin/env bash
# lfg stfu - Source Tree Forensics & Unification
# Comprehensive project portfolio analysis: deps, fingerprints, code patterns,
# shared library candidates, environment consolidation, AI semantic analysis
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HTML_FILE="$LFG_DIR/.lfg_stfu.html"
VIEWER="$LFG_DIR/viewer"
STFU_CORE="$LFG_DIR/lib/stfu_core.py"
STFU_REPORT="$LFG_DIR/lib/stfu_report.py"

source "$LFG_DIR/lib/state.sh" 2>/dev/null || true
lfg_state_start stfu 2>/dev/null || true

TARGET="${HOME}/Developer"
JSON_MODE=false
SUBCMD=""
AI_FLAG=""
EXTRA_ARGS=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)     JSON_MODE=true ;;
        --no-ai)    AI_FLAG="--no-ai" ;;
        --target)   TARGET="$2"; shift ;;
        deps|fingerprint|duplicates|libraries|envs)
                    SUBCMD="$1" ;;
        merge-check)
                    SUBCMD="merge-check"
                    shift; EXTRA_ARGS="$*"; break ;;
        archive)
                    SUBCMD="archive"
                    shift; EXTRA_ARGS="$*"; break ;;
        *)          [[ -d "$1" ]] && TARGET="$1" ;;
    esac
    shift
done

# Archive subcommand
if [[ "$SUBCMD" == "archive" ]]; then
    proj_name="$EXTRA_ARGS"
    proj_path="$TARGET/$proj_name"
    archive_dir="$TARGET/.archive"
    if [[ -z "$proj_name" ]]; then
        echo "Usage: lfg stfu archive <project-name>"
        exit 1
    fi
    if [[ ! -d "$proj_path" ]]; then
        echo "Project not found: $proj_path"
        exit 1
    fi
    mkdir -p "$archive_dir"
    ts=$(date +%Y%m%d_%H%M%S)
    dest="$archive_dir/${proj_name}_${ts}"
    echo "Archiving $proj_name -> $dest"
    mv "$proj_path" "$dest"
    echo "Archived successfully."
    exit 0
fi

# Run analysis
[[ "$JSON_MODE" != "true" ]] && echo "STFU: Analyzing $TARGET..."

if [[ -n "$SUBCMD" ]]; then
    # Subcommand mode
    python3 "$STFU_CORE" "$SUBCMD" $AI_FLAG --target "$TARGET" $EXTRA_ARGS
    exit $?
fi

# Full analysis
STFU_JSON=$(python3 "$STFU_CORE" full $AI_FLAG --target "$TARGET" 2>/dev/null)

if [[ "$JSON_MODE" == "true" ]]; then
    echo "$STFU_JSON"
    exit 0
fi

# Generate HTML report
python3 "$STFU_REPORT" "$HTML_FILE" <<< "$STFU_JSON"

lfg_state_done stfu "$(echo "$STFU_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin).get('summary',{}); print(f'projects={d.get(\"total_projects\",0)} dupes={d.get(\"duplicate_pairs\",0)} clusters={d.get(\"cluster_count\",0)} savings={d.get(\"estimated_savings_mb\",0)}MB')" 2>/dev/null)" 2>/dev/null || true

echo "Opening viewer..."
"$VIEWER" "$HTML_FILE" "LFG STFU - Source Tree Forensics" &
disown
echo "Done."

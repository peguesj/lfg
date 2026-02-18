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
source "$LFG_DIR/lib/settings.sh" 2>/dev/null || true
lfg_state_start stfu 2>/dev/null || true

# Default target from settings (first scan path)
TARGET=$(lfg_module_paths stfu 2>/dev/null | head -1)
TARGET="${TARGET:-$HOME/Developer}"
JSON_MODE=false
SUBCMD=""
AI_FLAG=""
EXTRA_ARGS=""
EXECUTE_MODE=false

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)     JSON_MODE=true ;;
        --no-ai)    AI_FLAG="--no-ai" ;;
        --target)   TARGET="$2"; shift ;;
        --dry-run)  EXECUTE_MODE=false ;;
        --execute)  EXECUTE_MODE=true ;;
        deps|fingerprint|duplicates|libraries|envs)
                    SUBCMD="$1" ;;
        merge-check)
                    SUBCMD="merge-check"
                    shift; EXTRA_ARGS="$*"; break ;;
        archive)
                    SUBCMD="archive"
                    shift; EXTRA_ARGS="$*"; break ;;
        scaffold)
                    SUBCMD="scaffold"
                    shift; EXTRA_ARGS="$*"; break ;;
        help|--help)
                    cat <<'HELP'
lfg stfu - Source Tree Forensics & Unification

USAGE:
    lfg stfu                         Full analysis (dry run, all paths)
    lfg stfu --execute               Enable action execution
    lfg stfu --json                  Output raw JSON
    lfg stfu --no-ai                 Skip AI analysis

SUBCOMMANDS:
    deps                             Dependency overlap analysis
    fingerprint                      File structure fingerprinting
    duplicates                       Code duplicate detection
    libraries                        Shared library candidates
    envs                             Environment consolidation groups
    merge-check <projA> <projB>      Check merge feasibility
    archive <project>                Move project to .archive/
    scaffold <library-name>          Generate shared library scaffold

FLAGS:
    --target <path>                  Override scan path
    --dry-run                        Show recommendations only (default)
    --execute                        Enable action execution with confirmation

EXAMPLES:
    lfg stfu                         Full forensics report
    lfg stfu deps                    Just dependency analysis
    lfg stfu merge-check lcc lcc-major-changes
    lfg stfu scaffold ui-core
    lfg stfu archive old-project
HELP
                    exit 0 ;;
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
    echo "  From: $proj_path"
    echo "  To:   $dest"
    echo "  Restore: mv '$dest' '$proj_path'"
    echo ""
    read -p "Proceed? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mv "$proj_path" "$dest"
        echo "Archived successfully."
        lfg_notify_apm "STFU Archive" "Archived $proj_name to $dest" "success" "lfg-stfu" 2>/dev/null || true
    else
        echo "Cancelled."
    fi
    exit 0
fi

# Scaffold subcommand
if [[ "$SUBCMD" == "scaffold" ]]; then
    lib_name="$EXTRA_ARGS"
    if [[ -z "$lib_name" ]]; then
        echo "Usage: lfg stfu scaffold <library-name>"
        exit 1
    fi
    namespace=$(lfg_settings_get library_namespace 2>/dev/null || echo "@jeremiah")
    full_name="${namespace}/${lib_name}"
    scaffold_dir="$TARGET/${lib_name}"

    echo "Scaffold: $full_name"
    echo "  Directory: $scaffold_dir"
    echo ""
    echo "  Will create:"
    echo "    package.json    - with name ${full_name}"
    echo "    tsconfig.json   - TypeScript config"
    echo "    src/index.ts    - Main entry point"
    echo "    README.md       - Documentation"
    echo ""

    if [[ -d "$scaffold_dir" ]]; then
        echo "Error: Directory already exists: $scaffold_dir"
        exit 1
    fi

    read -p "Create scaffold? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        mkdir -p "$scaffold_dir/src"

        cat > "$scaffold_dir/package.json" <<PKGJSON
{
  "name": "${full_name}",
  "version": "0.1.0",
  "description": "Shared ${lib_name} library",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "scripts": {
    "build": "tsc",
    "dev": "tsc --watch",
    "test": "vitest"
  },
  "devDependencies": {
    "typescript": "^5.0.0",
    "vitest": "^1.0.0"
  }
}
PKGJSON

        cat > "$scaffold_dir/tsconfig.json" <<TSCONFIG
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "declaration": true,
    "outDir": "dist",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
TSCONFIG

        cat > "$scaffold_dir/src/index.ts" <<'INDEXTS'
// Shared library entry point
// TODO: Extract shared code from source projects

export {}
INDEXTS

        cat > "$scaffold_dir/README.md" <<README
# ${full_name}

Shared library extracted by LFG STFU.

## Usage

\`\`\`bash
npm install ${full_name}
\`\`\`

## Source Projects

This library was identified as a candidate based on shared code patterns across your project portfolio.
README

        echo "Scaffold created at $scaffold_dir"
        lfg_notify_apm "STFU Scaffold" "Created $full_name at $scaffold_dir" "success" "lfg-stfu" 2>/dev/null || true
    else
        echo "Cancelled."
    fi
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

# Pass execute mode to report generator
REPORT_FLAGS=""
[[ "$EXECUTE_MODE" == "true" ]] && REPORT_FLAGS="--execute"

# Generate HTML report
python3 "$STFU_REPORT" "$HTML_FILE" $REPORT_FLAGS <<< "$STFU_JSON"

lfg_state_done stfu "$(echo "$STFU_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin).get('summary',{}); print(f'projects={d.get(\"total_projects\",0)} dupes={d.get(\"duplicate_pairs\",0)} clusters={d.get(\"cluster_count\",0)} savings={d.get(\"estimated_savings_mb\",0)}MB')" 2>/dev/null)" 2>/dev/null || true

echo "Opening viewer..."
"$VIEWER" "$HTML_FILE" "LFG STFU - Source Tree Forensics" &
disown
echo "Done."

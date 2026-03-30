#!/usr/bin/env bash
# =============================================================================
# inbox-send.sh — Submit a work item to the LFG inbox watcher
# =============================================================================
# Usage from any Claude Code session or script:
#
#   # Submit a cache relocation request
#   bash ~/tools/@yj/lfg/scripts/inbox-send.sh \
#     --type cache-relocate \
#     --from "my-project" \
#     --payload '{"path":"~/.npm","volume":"auto"}' \
#     --priority high
#
#   # Query volumes
#   bash ~/tools/@yj/lfg/scripts/inbox-send.sh \
#     --type volume-query \
#     --from "viki" \
#     --wait   # blocks until response arrives
#
#   # Protect a path from DTF
#   bash ~/tools/@yj/lfg/scripts/inbox-send.sh \
#     --type dtf-protect \
#     --from "strategic-thinking" \
#     --payload '{"path":"~/Developer/strategic-thinking/node_modules"}'
#
#   # Request DTF prefetch after cleanup
#   bash ~/tools/@yj/lfg/scripts/inbox-send.sh \
#     --type hook-prefetch \
#     --from "post-dtf-hook"
# =============================================================================
set -euo pipefail

INBOX_DIR="$HOME/.config/lfg/inbox"
PENDING="$INBOX_DIR/pending"
RESPONSES="$INBOX_DIR/responses"

TYPE="custom"
FROM="${CLAUDE_PROJECT_NAME:-unknown}"
PRIORITY="normal"
PAYLOAD="{}"
CALLBACK=""
WAIT=false
TIMEOUT=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type)     TYPE="$2"; shift 2 ;;
        --from)     FROM="$2"; shift 2 ;;
        --priority) PRIORITY="$2"; shift 2 ;;
        --payload)  PAYLOAD="$2"; shift 2 ;;
        --callback) CALLBACK="$2"; shift 2 ;;
        --wait)     WAIT=true; shift ;;
        --timeout)  TIMEOUT="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

ID=$(python3 -c "import uuid; print(str(uuid.uuid4())[:8])")
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$PENDING" "$RESPONSES"

# Set callback for --wait mode
if $WAIT && [[ -z "$CALLBACK" ]]; then
    CALLBACK="$RESPONSES/$ID.json"
fi

# Write work item
python3 -c "
import json
item = {
    'id': '$ID',
    'from': '$FROM',
    'type': '$TYPE',
    'priority': '$PRIORITY',
    'payload': json.loads('$PAYLOAD'),
    'callback': '$CALLBACK',
    'created_at': '$CREATED'
}
with open('$PENDING/$ID.json', 'w') as f:
    json.dump(item, f, indent=2)
print('$ID')
"

if $WAIT; then
    # Poll for response
    elapsed=0
    while [[ $elapsed -lt $TIMEOUT ]]; do
        if [[ -f "$CALLBACK" ]]; then
            cat "$CALLBACK"
            exit 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo '{"error":"timeout","id":"'$ID'"}' >&2
    exit 1
fi

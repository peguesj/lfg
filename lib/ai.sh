#!/usr/bin/env bash
# lfg ai - AI integration layer for project analysis
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AI_CONFIG="$HOME/.config/lfg/ai.yaml"
AI_HELPER="$LFG_DIR/lib/ai_helper.py"

ensure_config() {
    local dir; dir=$(dirname "$AI_CONFIG")
    [[ -d "$dir" ]] || mkdir -p "$dir"
    if [[ ! -f "$AI_CONFIG" ]]; then
        cat > "$AI_CONFIG" << 'EOF'
model: gpt-4o-mini
endpoint: http://localhost:4000
temperature: 0.3
system_override: false
max_tokens: 1024
EOF
    fi
}

cmd_config() {
    ensure_config
    case "${1:-show}" in
        show) cat "$AI_CONFIG" ;;
        get)
            [[ -z "${2:-}" ]] && { echo "Usage: lfg ai config get <key>"; exit 1; }
            python3 -c "
import yaml, sys
with open('$AI_CONFIG') as f:
    cfg = yaml.safe_load(f) or {}
val = cfg.get('$2', '')
print(val if val is not None else '')
" 2>/dev/null || echo ""
            ;;
        set)
            [[ -z "${2:-}" || -z "${3:-}" ]] && { echo "Usage: lfg ai config set <key> <value>"; exit 1; }
            python3 -c "
import yaml
with open('$AI_CONFIG') as f:
    cfg = yaml.safe_load(f) or {}
val = '$3'
if val == 'true': val = True
elif val == 'false': val = False
else:
    try: val = float(val)
    except: pass
cfg['$2'] = val
with open('$AI_CONFIG', 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False)
print('Set $2 = $3')
" 2>/dev/null
            ;;
        reset)
            rm -f "$AI_CONFIG"
            ensure_config
            echo "Config reset to defaults"
            ;;
        *) echo "Usage: lfg ai config [show|get|set|reset]"; exit 1 ;;
    esac
}

cmd_analyze() {
    ensure_config
    local target="${1:-}"
    [[ -z "$target" ]] && { echo '{"error":"Usage: lfg ai analyze <path>"}'; exit 1; }
    [[ ! -d "$target" ]] && target="$HOME/Developer/$target"
    [[ ! -d "$target" ]] && { echo '{"error":"Directory not found"}'; exit 1; }
    python3 "$AI_HELPER" analyze "$target"
}

cmd_compare() {
    ensure_config
    local a="${1:-}" b="${2:-}"
    [[ -z "$a" || -z "$b" ]] && { echo '{"error":"Usage: lfg ai compare <pathA> <pathB>"}'; exit 1; }
    [[ ! -d "$a" ]] && a="$HOME/Developer/$a"
    [[ ! -d "$b" ]] && b="$HOME/Developer/$b"
    python3 "$AI_HELPER" compare "$a" "$b"
}

cmd_suggest() {
    ensure_config
    local target="${1:-}"
    [[ -z "$target" ]] && { echo '{"error":"Usage: lfg ai suggest <path>"}'; exit 1; }
    [[ ! -d "$target" ]] && target="$HOME/Developer/$target"
    python3 "$AI_HELPER" suggest "$target"
}

case "${1:-}" in
    config)  shift; cmd_config "$@" ;;
    analyze) shift; cmd_analyze "$@" ;;
    compare) shift; cmd_compare "$@" ;;
    suggest) shift; cmd_suggest "$@" ;;
    *)       echo "Usage: lfg ai [config|analyze|compare|suggest]"; exit 1 ;;
esac

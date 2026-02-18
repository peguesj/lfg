#!/usr/bin/env bash
# =============================================================================
# lfg settings - Centralized settings management
# =============================================================================
# Config: ~/.config/lfg/settings.yaml
# All modules source this to get scan_paths, module_access, preferences.
# =============================================================================

readonly LFG_SETTINGS_DIR="$HOME/.config/lfg"
readonly LFG_SETTINGS_FILE="$LFG_SETTINGS_DIR/settings.yaml"

mkdir -p "$LFG_SETTINGS_DIR"

# Create default settings if missing
_lfg_ensure_settings() {
    [[ -f "$LFG_SETTINGS_FILE" ]] && return
    cat > "$LFG_SETTINGS_FILE" <<'DEFAULTS'
# LFG Settings
# Managed by: lfg settings

scan_paths:
  - ~/Developer

library_namespace: "@jeremiah"

theme: dark

module_access:
  wtfs: all
  dtf: all
  btau: all
  devdrive: all
  stfu: all

ai:
  model: gpt-4o-mini
  endpoint: http://localhost:4000
  temperature: 0.3
  system_override: false
DEFAULTS
}

_lfg_ensure_settings

# Python helper for YAML-like operations (no external deps)
# We use a simple key-value parser since our YAML is flat/simple
_lfg_settings_py() {
    python3 -c "
import os, sys, re

SETTINGS = '$LFG_SETTINGS_FILE'

def read_settings():
    \"\"\"Parse our simple YAML into a dict.\"\"\"
    settings = {}
    current_key = None
    current_list = None
    with open(SETTINGS) as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue
            # List item under a key
            if stripped.startswith('- ') and current_key:
                if current_list is None:
                    current_list = []
                val = stripped[2:].strip().strip('\"').strip(\"'\")
                current_list.append(val)
                settings[current_key] = current_list
                continue
            # Nested key under a parent (2-space indent)
            if line.startswith('  ') and not stripped.startswith('-'):
                m = re.match(r'\s+(\w+):\s*(.*)', line)
                if m and current_key:
                    sub_key = m.group(1)
                    sub_val = m.group(2).strip().strip('\"').strip(\"'\")
                    if not isinstance(settings.get(current_key), dict):
                        settings[current_key] = {}
                    # Parse 'all' or list
                    settings[current_key][sub_key] = sub_val if sub_val else 'all'
                    current_list = None
                continue
            # Top-level key
            m = re.match(r'^(\w+):\s*(.*)', line)
            if m:
                current_key = m.group(1)
                val = m.group(2).strip().strip('\"').strip(\"'\")
                current_list = None
                if val:
                    settings[current_key] = val
                # else: will be populated by subsequent lines
    return settings

def write_settings(settings):
    \"\"\"Write settings back as YAML.\"\"\"
    lines = ['# LFG Settings', '# Managed by: lfg settings', '']
    for key, val in settings.items():
        if isinstance(val, list):
            lines.append(f'{key}:')
            for item in val:
                lines.append(f'  - {item}')
        elif isinstance(val, dict):
            lines.append(f'{key}:')
            for k, v in val.items():
                lines.append(f'  {k}: {v}')
        else:
            lines.append(f'{key}: {val}')
        lines.append('')
    with open(SETTINGS, 'w') as f:
        f.write('\n'.join(lines) + '\n')

$1
" "${@:2}" 2>/dev/null
}

# ─── Public API ──────────────────────────────────────────────────────────────

# Get a setting value. For scan_paths returns newline-separated list.
# Usage: lfg_settings_get scan_paths
#        lfg_settings_get library_namespace
#        lfg_settings_get module_access.stfu
lfg_settings_get() {
    local key="$1"
    _lfg_settings_py "
s = read_settings()
key = '${key}'
if '.' in key:
    parent, child = key.split('.', 1)
    val = s.get(parent, {})
    if isinstance(val, dict):
        print(val.get(child, ''))
    else:
        print('')
else:
    val = s.get(key, '')
    if isinstance(val, list):
        for v in val:
            print(os.path.expanduser(v))
    elif isinstance(val, dict):
        import json
        print(json.dumps(val))
    else:
        print(val)
"
}

# Set a setting value
# Usage: lfg_settings_set library_namespace "@myorg"
lfg_settings_set() {
    local key="$1" value="$2"
    _lfg_settings_py "
s = read_settings()
key = '${key}'
value = '${value}'
if '.' in key:
    parent, child = key.split('.', 1)
    if parent not in s or not isinstance(s[parent], dict):
        s[parent] = {}
    s[parent][child] = value
else:
    s[key] = value
write_settings(s)
print('OK')
"
}

# Add a path to scan_paths
# Usage: lfg_settings_paths_add /Volumes/DevDrive/src
lfg_settings_paths_add() {
    local path="$1"
    _lfg_settings_py "
s = read_settings()
paths = s.get('scan_paths', [])
if not isinstance(paths, list):
    paths = [paths] if paths else []
expanded = os.path.expanduser('${path}')
short = '${path}'
# Store as given (with ~ if applicable)
if expanded not in [os.path.expanduser(p) for p in paths]:
    paths.append(short)
    s['scan_paths'] = paths
    write_settings(s)
    print(f'Added: {short}')
else:
    print(f'Already exists: {short}')
"
}

# Remove a path from scan_paths
lfg_settings_paths_remove() {
    local path="$1"
    _lfg_settings_py "
s = read_settings()
paths = s.get('scan_paths', [])
expanded_target = os.path.expanduser('${path}')
new_paths = [p for p in paths if os.path.expanduser(p) != expanded_target]
if len(new_paths) < len(paths):
    s['scan_paths'] = new_paths
    write_settings(s)
    print(f'Removed: ${path}')
else:
    print(f'Not found: ${path}')
"
}

# Grant module access to a path
lfg_settings_access_add() {
    local module="$1" path="$2"
    _lfg_settings_py "
s = read_settings()
access = s.get('module_access', {})
if not isinstance(access, dict):
    access = {}
current = access.get('${module}', 'all')
if current == 'all':
    print('Module ${module} already has access to all paths')
else:
    if isinstance(current, str):
        current = [current] if current else []
    if '${path}' not in current:
        current.append('${path}')
    access['${module}'] = ','.join(current) if len(current) > 1 else current[0]
    s['module_access'] = access
    write_settings(s)
    print('Granted ${module} access to ${path}')
"
}

# Revoke module access to a path
lfg_settings_access_remove() {
    local module="$1" path="$2"
    _lfg_settings_py "
s = read_settings()
access = s.get('module_access', {})
current = access.get('${module}', 'all')
if current == 'all':
    # Switch from 'all' to explicit list minus this path
    paths = s.get('scan_paths', [])
    expanded_remove = os.path.expanduser('${path}')
    new_list = [p for p in paths if os.path.expanduser(p) != expanded_remove]
    access['${module}'] = ','.join(new_list) if len(new_list) > 1 else (new_list[0] if new_list else '')
else:
    parts = [p.strip() for p in current.split(',')]
    parts = [p for p in parts if os.path.expanduser(p) != os.path.expanduser('${path}')]
    access['${module}'] = ','.join(parts) if parts else ''
s['module_access'] = access
write_settings(s)
print('Revoked ${module} access to ${path}')
"
}

# Show all settings (YAML format)
lfg_settings_show() {
    cat "$LFG_SETTINGS_FILE"
}

# Show settings as JSON (for UI consumption)
lfg_settings_show_json() {
    _lfg_settings_py "
import json
s = read_settings()
# Expand paths
if 'scan_paths' in s and isinstance(s['scan_paths'], list):
    s['scan_paths_expanded'] = [os.path.expanduser(p) for p in s['scan_paths']]
print(json.dumps(s, indent=2))
"
}

# Reset to defaults
lfg_settings_reset() {
    rm -f "$LFG_SETTINGS_FILE"
    _lfg_ensure_settings
    echo "Settings reset to defaults."
}

# ─── Module Helpers ──────────────────────────────────────────────────────────

# Get scan paths for a specific module (respects module_access)
# Usage: paths=$(lfg_module_paths stfu)
# Returns newline-separated expanded paths
lfg_module_paths() {
    local module="$1"
    _lfg_settings_py "
s = read_settings()
all_paths = s.get('scan_paths', ['~/Developer'])
if not isinstance(all_paths, list):
    all_paths = [all_paths]

access = s.get('module_access', {})
module_access = access.get('${module}', 'all')

if module_access == 'all':
    for p in all_paths:
        print(os.path.expanduser(p))
else:
    allowed = set(os.path.expanduser(a.strip()) for a in module_access.split(',') if a.strip())
    all_expanded = {os.path.expanduser(p): p for p in all_paths}
    for expanded, original in all_expanded.items():
        if expanded in allowed:
            print(expanded)
"
}

# ─── CLI Dispatcher ──────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Running as a script (lfg settings ...)
    cmd="${1:-show}"
    shift 2>/dev/null || true

    case "$cmd" in
        show)
            if [[ "${1:-}" == "--json" ]]; then
                lfg_settings_show_json
            else
                lfg_settings_show
            fi
            ;;
        get)
            lfg_settings_get "$1"
            ;;
        set)
            lfg_settings_set "$1" "$2"
            ;;
        paths)
            subcmd="${1:-list}"
            shift 2>/dev/null || true
            case "$subcmd" in
                list)   lfg_settings_get scan_paths ;;
                add)    lfg_settings_paths_add "$1" ;;
                remove) lfg_settings_paths_remove "$1" ;;
                *)      echo "Usage: lfg settings paths [list|add|remove] <path>" ;;
            esac
            ;;
        access)
            module="${1:-}"
            subcmd="${2:-show}"
            path="${3:-}"
            case "$subcmd" in
                add)    lfg_settings_access_add "$module" "$path" ;;
                remove) lfg_settings_access_remove "$module" "$path" ;;
                show)   lfg_settings_get "module_access.$module" ;;
                *)      echo "Usage: lfg settings access <module> [add|remove|show] <path>" ;;
            esac
            ;;
        reset)
            lfg_settings_reset
            ;;
        help|--help)
            cat <<'HELP'
lfg settings - Manage LFG configuration

COMMANDS:
    show [--json]                    Show all settings
    get <key>                        Get a setting (e.g. library_namespace, scan_paths)
    set <key> <value>                Set a setting
    paths list                       List scan paths
    paths add <path>                 Add a scan path
    paths remove <path>              Remove a scan path
    access <module> show             Show module path access
    access <module> add <path>       Grant module access to path
    access <module> remove <path>    Revoke module access to path
    reset                            Reset all settings to defaults

EXAMPLES:
    lfg settings paths add /Volumes/DevDrive/src
    lfg settings set library_namespace "@myorg"
    lfg settings access stfu add /Volumes/DevDrive/src
    lfg settings show --json
HELP
            ;;
        *)
            echo "Unknown settings command: $cmd"
            echo "Run 'lfg settings help' for usage."
            exit 1
            ;;
    esac
fi

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

volume_profiles:
  - name: 900DEVELOPER
    purpose: Developer projects
    system_link: ~/Developer
    file_patterns: []
    color: "#c084fc"
    auto_move_policy: largest_to_freest
  - name: 901LOGIC
    purpose: Logic Pro sessions
    system_link: ~/Music/Logic
    file_patterns:
      - "*.logicx"
      - "*.band"
    color: "#ff6b8a"
    auto_move_policy: largest_to_freest
DEFAULTS
}

_lfg_ensure_settings

# Python helper for YAML-like operations (no external deps)
# Supports: scalars, simple lists, dicts, and list-of-dicts (volume_profiles)
_lfg_settings_py() {
    python3 -c "
import os, sys, re

SETTINGS = '$LFG_SETTINGS_FILE'

def read_settings():
    \"\"\"Parse LFG YAML into a dict. Handles list-of-dicts (volume_profiles).\"\"\"
    settings = {}
    current_key = None
    current_list = None
    current_dict_item = None  # for list-of-dicts items
    current_dict_sub_list = None  # for sub-lists within dict items (e.g. file_patterns)
    current_dict_sub_key = None

    with open(SETTINGS) as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue

            indent = len(line) - len(line.lstrip())

            # Top-level key (no indent)
            if indent == 0:
                # Flush any pending dict item
                if current_dict_item is not None and current_key:
                    if current_dict_sub_list is not None and current_dict_sub_key:
                        current_dict_item[current_dict_sub_key] = current_dict_sub_list
                    if current_list is None:
                        current_list = []
                    current_list.append(current_dict_item)
                    settings[current_key] = current_list
                    current_dict_item = None
                    current_dict_sub_list = None
                    current_dict_sub_key = None

                m = re.match(r'^(\w+):\s*(.*)', line)
                if m:
                    current_key = m.group(1)
                    val = m.group(2).strip().strip('\"').strip(\"'\")
                    current_list = None
                    current_dict_item = None
                    current_dict_sub_list = None
                    current_dict_sub_key = None
                    if val:
                        settings[current_key] = val
                continue

            # 2-space indent
            if indent == 2 and current_key:
                # List item: '  - ...'
                if stripped.startswith('- '):
                    rest = stripped[2:].strip()
                    # Check if this is a dict item (has key: val)
                    m = re.match(r'^(\w[\w_]*):\s*(.*)', rest)
                    if m:
                        # Flush previous dict item
                        if current_dict_item is not None:
                            if current_dict_sub_list is not None and current_dict_sub_key:
                                current_dict_item[current_dict_sub_key] = current_dict_sub_list
                            if current_list is None:
                                current_list = []
                            current_list.append(current_dict_item)
                        current_dict_item = {}
                        current_dict_sub_list = None
                        current_dict_sub_key = None
                        dk = m.group(1)
                        dv = m.group(2).strip().strip('\"').strip(\"'\")
                        if dv == '[]':
                            current_dict_item[dk] = []
                        else:
                            current_dict_item[dk] = dv
                    else:
                        # Simple list item
                        val = rest.strip('\"').strip(\"'\")
                        if current_list is None:
                            current_list = []
                        current_list.append(val)
                        settings[current_key] = current_list
                    continue
                # Nested key: '  key: val'
                m = re.match(r'\s+(\w[\w_]*):\s*(.*)', line)
                if m and current_dict_item is None:
                    sub_key = m.group(1)
                    sub_val = m.group(2).strip().strip('\"').strip(\"'\")
                    if not isinstance(settings.get(current_key), dict):
                        settings[current_key] = {}
                    settings[current_key][sub_key] = sub_val if sub_val else 'all'
                    current_list = None
                continue

            # 4-space indent (inside a dict item of a list-of-dicts)
            if indent == 4 and current_dict_item is not None:
                # Sub-list item: '      - ...'
                if stripped.startswith('- '):
                    val = stripped[2:].strip().strip('\"').strip(\"'\")
                    if current_dict_sub_list is None:
                        current_dict_sub_list = []
                    current_dict_sub_list.append(val)
                    if current_dict_sub_key:
                        current_dict_item[current_dict_sub_key] = current_dict_sub_list
                    continue
                # Dict key inside list item: '    key: val'
                m = re.match(r'\s+(\w[\w_]*):\s*(.*)', line)
                if m:
                    # Flush previous sub-list
                    if current_dict_sub_list is not None and current_dict_sub_key:
                        current_dict_item[current_dict_sub_key] = current_dict_sub_list
                    dk = m.group(1)
                    dv = m.group(2).strip().strip('\"').strip(\"'\")
                    current_dict_sub_list = None
                    current_dict_sub_key = dk
                    if dv == '[]':
                        current_dict_item[dk] = []
                        current_dict_sub_key = None
                    elif dv:
                        current_dict_item[dk] = dv
                        current_dict_sub_key = None
                    else:
                        # Value will come as sub-list items
                        current_dict_sub_list = []
                continue

            # 6-space indent (sub-list items inside dict item properties)
            if indent >= 6 and current_dict_item is not None and current_dict_sub_key:
                if stripped.startswith('- '):
                    val = stripped[2:].strip().strip('\"').strip(\"'\")
                    if current_dict_sub_list is None:
                        current_dict_sub_list = []
                    current_dict_sub_list.append(val)
                    current_dict_item[current_dict_sub_key] = current_dict_sub_list
                continue

    # Flush final dict item
    if current_dict_item is not None and current_key:
        if current_dict_sub_list is not None and current_dict_sub_key:
            current_dict_item[current_dict_sub_key] = current_dict_sub_list
        if current_list is None:
            current_list = []
        current_list.append(current_dict_item)
        settings[current_key] = current_list

    return settings

def write_settings(settings):
    \"\"\"Write settings back as YAML. Handles list-of-dicts.\"\"\"
    lines = ['# LFG Settings', '# Managed by: lfg settings', '']
    for key, val in settings.items():
        if isinstance(val, list) and val and isinstance(val[0], dict):
            # List of dicts (e.g. volume_profiles)
            lines.append(f'{key}:')
            for item in val:
                first = True
                for dk, dv in item.items():
                    prefix = '  - ' if first else '    '
                    first = False
                    if isinstance(dv, list):
                        if not dv:
                            lines.append(f'{prefix}{dk}: []')
                        else:
                            lines.append(f'{prefix}{dk}:')
                            for sv in dv:
                                lines.append(f'      - \\\"{sv}\\\"')
                    else:
                        dv_str = f'\\\"{dv}\\\"' if isinstance(dv, str) and (dv.startswith('#') or dv.startswith('@')) else dv
                        lines.append(f'{prefix}{dk}: {dv_str}')
        elif isinstance(val, list):
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
    s['scan_paths_expanded'] = [os.path.expanduser(p) for p in s['scan_paths'] if isinstance(p, str)]
# Ensure volume_profiles defaults
defaults = {'name':'','purpose':'','system_link':'','file_patterns':[],'color':'#c084fc','auto_move_policy':'manual'}
profiles = s.get('volume_profiles', [])
if isinstance(profiles, list):
    for p in profiles:
        if isinstance(p, dict):
            for dk, dv in defaults.items():
                if dk not in p:
                    p[dk] = dv
            if isinstance(p.get('file_patterns'), str):
                p['file_patterns'] = [p['file_patterns']] if p['file_patterns'] else []
            p['system_link_expanded'] = os.path.expanduser(p.get('system_link', ''))
            p['mounted'] = os.path.isdir(f\"/Volumes/{p.get('name','')}\")
    s['volume_profiles'] = profiles
print(json.dumps(s, indent=2))
"
}

# Reset to defaults
lfg_settings_reset() {
    rm -f "$LFG_SETTINGS_FILE"
    _lfg_ensure_settings
    echo "Settings reset to defaults."
}

# ─── Volume Profile Helpers ──────────────────────────────────────────────────

# Get volume profiles as JSON array
# Usage: profiles_json=$(lfg_settings_get_profiles)
lfg_settings_get_profiles() {
    _lfg_settings_py "
import json
s = read_settings()
profiles = s.get('volume_profiles', [])
if not isinstance(profiles, list):
    profiles = []
# Ensure each profile has all fields with defaults
defaults = {'name':'','purpose':'','system_link':'','file_patterns':[],'color':'#c084fc','auto_move_policy':'manual'}
for p in profiles:
    for dk, dv in defaults.items():
        if dk not in p:
            p[dk] = dv
    if isinstance(p.get('file_patterns'), str):
        p['file_patterns'] = [p['file_patterns']] if p['file_patterns'] else []
print(json.dumps(profiles))
"
}

# Get profile names as newline-separated list
lfg_settings_get_profile_names() {
    _lfg_settings_py "
s = read_settings()
profiles = s.get('volume_profiles', [])
if isinstance(profiles, list):
    for p in profiles:
        if isinstance(p, dict):
            print(p.get('name', ''))
"
}

# Get a specific profile by name as JSON
# Usage: profile_json=$(lfg_settings_get_profile "901LOGIC")
lfg_settings_get_profile() {
    local name="$1"
    _lfg_settings_py "
import json
s = read_settings()
profiles = s.get('volume_profiles', [])
for p in profiles:
    if isinstance(p, dict) and p.get('name') == '${name}':
        print(json.dumps(p))
        break
"
}

# Get list of mounted volume profile names
lfg_settings_get_mounted_profiles() {
    _lfg_settings_py "
s = read_settings()
profiles = s.get('volume_profiles', [])
if isinstance(profiles, list):
    for p in profiles:
        if isinstance(p, dict):
            name = p.get('name', '')
            if name and os.path.isdir(f'/Volumes/{name}'):
                print(name)
"
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

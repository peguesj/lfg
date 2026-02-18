#!/usr/bin/env bash
# lfg devdrive - Developer Drive (symlink forest manager with WebKit report)
set -uo pipefail

LFG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEVDRIVE_DIR="$HOME/tools/yj-devdrive"
HTML_FILE="$LFG_DIR/.lfg_devdrive.html"
VIEWER="$LFG_DIR/viewer"
MOUNT_POINT="/Volumes/900DEVELOPER"

source "$LFG_DIR/lib/state.sh"

# Pass-through to devdrive subcommands
case "${1:-}" in
    mount)
        lfg_state_start devdrive
        echo "Mounting devdrive sparse image..."
        export PYTHONPATH="${DEVDRIVE_DIR}:${PYTHONPATH:-}"
        python3 -c "
from btau.core.sparse import attach_sparse_image
import json, glob, os
images = glob.glob(os.path.expanduser('~/.config/btau/*.sparseimage')) + glob.glob('/Volumes/*/900DEVELOPER.sparseimage')
if images:
    result = attach_sparse_image(images[0])
    print(json.dumps(result, indent=2))
else:
    print('No sparse image found. Create one with: lfg btau create-image')
"
        lfg_state_done devdrive "action=mount"
        exit 0
        ;;
    unmount)
        lfg_state_start devdrive
        echo "Unmounting devdrive..."
        if [[ -d "$MOUNT_POINT" ]]; then
            hdiutil detach "$MOUNT_POINT" 2>/dev/null || diskutil unmount "$MOUNT_POINT" 2>/dev/null
            echo "Unmounted $MOUNT_POINT"
        else
            echo "Not mounted: $MOUNT_POINT"
        fi
        lfg_state_done devdrive "action=unmount"
        exit 0
        ;;
    sync)
        lfg_state_start devdrive
        echo "Rebuilding symlink forest..."
        export PYTHONPATH="${DEVDRIVE_DIR}:${PYTHONPATH:-}"
        python3 -c "
from btau.core.devdrive import rebuild_forest
from pathlib import Path
import json
result = rebuild_forest(Path('$MOUNT_POINT'))
print(json.dumps(result, indent=2))
"
        lfg_state_done devdrive "action=sync"
        exit 0
        ;;
    verify)
        lfg_state_start devdrive
        echo "Verifying symlink health..."
        export PYTHONPATH="${DEVDRIVE_DIR}:${PYTHONPATH:-}"
        python3 -c "
from btau.core.devdrive import check_forest_health
from pathlib import Path
import json
result = check_forest_health(Path('$MOUNT_POINT'))
print(json.dumps(result, indent=2))
"
        lfg_state_done devdrive "action=verify"
        exit 0
        ;;
    config)
        shift
        lfg_state_start devdrive
        export PYTHONPATH="${DEVDRIVE_DIR}:${PYTHONPATH:-}"
        case "${1:-show}" in
            get)
                shift
                KEY="${1:-}"
                if [[ -z "$KEY" ]]; then
                    echo "Usage: lfg devdrive config get <key>"
                    echo "  Keys: mount_mode, developer_dir, sparse_mount, auto_move.enabled, ..."
                    exit 1
                fi
                python3 -c "
from btau.core.config import get_config
try:
    val = get_config('$KEY')
    print(val)
except KeyError as e:
    print(f'Error: {e}')
"
                ;;
            set)
                shift
                KEY="${1:-}"; VALUE="${2:-}"
                if [[ -z "$KEY" || -z "$VALUE" ]]; then
                    echo "Usage: lfg devdrive config set <key> <value>"
                    exit 1
                fi
                python3 -c "
from btau.core.config import set_config
cfg = set_config('$KEY', '$VALUE')
print('Set $KEY = $VALUE')
"
                ;;
            reset)
                python3 -c "
from btau.core.config import reset_config
reset_config()
print('Config reset to defaults.')
"
                ;;
            show|*)
                python3 -c "
from btau.core.config import load_config
import yaml
cfg = load_config()
print(yaml.dump(cfg, default_flow_style=False, sort_keys=False))
"
                ;;
        esac
        lfg_state_done devdrive "action=config"
        exit 0
        ;;
    auto-move)
        shift
        lfg_state_start devdrive
        export PYTHONPATH="${DEVDRIVE_DIR}:${PYTHONPATH:-}"
        DRY_RUN="True"
        FORCE=""
        for arg in "$@"; do
            case "$arg" in
                --force) DRY_RUN="False"; FORCE="yes" ;;
                --dry-run) DRY_RUN="True" ;;
            esac
        done
        if [[ -n "$FORCE" ]]; then
            echo "Executing auto-move (LIVE)..."
        else
            echo "Evaluating auto-move rules (dry run)..."
        fi
        python3 -c "
import json
from btau.core.automove import AutoMoveEngine

engine = AutoMoveEngine.from_config()
proposals = engine.evaluate_rules()

if not proposals:
    print('No projects match auto-move criteria.')
else:
    print(f'{len(proposals)} project(s) eligible for migration:')
    print()
    for p in proposals:
        d = p.to_dict()
        print(f'  {d[\"project_name\"]:30s} {d[\"size_gb\"]:6.1f} GB  {d[\"days_since_access\"]:5.0f}d  score={d[\"score\"]:.1f}')
        print(f'    reason: {d[\"reason\"]}')
        print(f'    {d[\"source\"]} -> {d[\"destination\"]}')
        print()

    results = engine.execute_plan(proposals, dry_run=$DRY_RUN)
    for r in results:
        status = r['status']
        name = r['project']
        if status == 'dry_run':
            print(f'  [DRY RUN] {name}')
        elif status == 'success':
            print(f'  [MOVED]   {name}')
        else:
            print(f'  [ERROR]   {name}: {r.get(\"error\", \"unknown\")}')
"
        lfg_state_done devdrive "action=auto-move" "dry_run=$DRY_RUN"
        exit 0
        ;;
    create)
        shift
        PROJECT_NAME="${1:-}"
        if [[ -z "$PROJECT_NAME" ]]; then
            echo "Usage: lfg devdrive create <project-name> [volume]"
            exit 1
        fi
        TARGET_VOL="${2:-}"
        lfg_state_start devdrive
        echo "Creating project '$PROJECT_NAME'..."
        export PYTHONPATH="${DEVDRIVE_DIR}:${PYTHONPATH:-}"
        python3 -c "
from btau.core.devdrive import create_project
import json
result = create_project('$PROJECT_NAME', target_volume='$TARGET_VOL' if '$TARGET_VOL' else None)
print(json.dumps(result, indent=2))
"
        lfg_state_done devdrive "action=create" "project=$PROJECT_NAME"
        exit 0
        ;;
esac

# Status view mode -- show devdrive status in WebKit viewer
lfg_state_start devdrive
echo "Gathering devdrive status..."

TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# Check mount status
MOUNTED="false"
MOUNT_SIZE=""
MOUNT_FREE=""
if [[ -d "$MOUNT_POINT" ]]; then
    MOUNTED="true"
    MOUNT_INFO=$(df -h "$MOUNT_POINT" 2>/dev/null | awk 'NR==2{print $2 "|" $4}')
    MOUNT_SIZE=$(echo "$MOUNT_INFO" | cut -d'|' -f1)
    MOUNT_FREE=$(echo "$MOUNT_INFO" | cut -d'|' -f2)
fi

# Gather data via Python
export PYTHONPATH="${DEVDRIVE_DIR}:${PYTHONPATH:-}"

VOLUME_ROWS=""
VOLUME_COUNT=0
PROJECT_ROWS=""
PROJECT_COUNT=0
HEALTHY_COUNT=0
BROKEN_COUNT=0

# Get volumes, health, and projects from yj-devdrive
DEVDRIVE_DATA=$(python3 -c "
import json, sys
sys.path.insert(0, '$DEVDRIVE_DIR')
try:
    from btau.core.volumes import find_devdrive_volumes
    from btau.core.devdrive import check_forest_health, list_projects
    from pathlib import Path

    volumes = find_devdrive_volumes()
    vol_data = []
    for v in volumes:
        total_gb = v.get('total_bytes', 0) / (1024**3)
        free_gb = v.get('free_bytes', 0) / (1024**3)
        proj_count = len(v.get('projects', []))
        vol_data.append({
            'name': v['name'],
            'mount_point': v.get('mount_point', ''),
            'total_gb': round(total_gb, 1),
            'free_gb': round(free_gb, 1),
            'fs_type': v.get('fs_type', ''),
            'project_count': proj_count,
            'projects': v.get('projects', []),
        })

    health = check_forest_health(Path('$MOUNT_POINT'))
    projects = list_projects(Path('$MOUNT_POINT'))

    print(json.dumps({
        'volumes': vol_data,
        'health': health,
        'projects': projects,
    }))
except Exception as e:
    print(json.dumps({
        'error': str(e),
        'volumes': [],
        'health': {'healthy':[],'broken':[],'not_symlink':[],'total':0},
        'projects': [],
    }))
" 2>/dev/null || echo '{"error":"python failed","volumes":[],"health":{"healthy":[],"broken":[],"not_symlink":[],"total":0},"projects":[]}')

# Parse volume rows
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    vol_name=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name','?'))" 2>/dev/null || echo "?")
    vol_mount=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('mount_point',''))" 2>/dev/null || echo "")
    vol_total=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('total_gb',0):.1f} GB\")" 2>/dev/null || echo "?")
    vol_free=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('free_gb',0):.1f} GB\")" 2>/dev/null || echo "?")
    vol_fs=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fs_type',''))" 2>/dev/null || echo "")
    vol_projs=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('project_count',0))" 2>/dev/null || echo "0")

    VOLUME_COUNT=$((VOLUME_COUNT + 1))
    VOLUME_ROWS+="<tr data-tip=\"${vol_name}: ${vol_total} total, ${vol_free} free, ${vol_projs} projects\">
      <td class=\"name\">${vol_name}</td>
      <td>${vol_mount}</td>
      <td class=\"size\">${vol_total}</td>
      <td class=\"size\">${vol_free}</td>
      <td>${vol_fs}</td>
      <td class=\"rank\">${vol_projs}</td>
    </tr>"
done < <(echo "$DEVDRIVE_DATA" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for v in data.get('volumes', []):
    print(json.dumps(v))
" 2>/dev/null)

# Parse project rows
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    proj_name=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('name','?'))" 2>/dev/null || echo "?")
    proj_source=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('source_path',''))" 2>/dev/null || echo "")
    proj_vol=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('source_volume','') or '-')" 2>/dev/null || echo "-")
    proj_alive=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('alive') else 'false')" 2>/dev/null || echo "false")
    proj_symlink=$(echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('is_symlink') else 'false')" 2>/dev/null || echo "false")

    PROJECT_COUNT=$((PROJECT_COUNT + 1))

    if [[ "$proj_alive" == "true" ]]; then
        status_class="badge-cleaned"
        status_text="HEALTHY"
        HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
    else
        status_class="badge-error"
        status_text="BROKEN"
        BROKEN_COUNT=$((BROKEN_COUNT + 1))
    fi

    if [[ "$proj_symlink" == "true" ]]; then
        type_badge="<span class=\"status-badge badge-active\">LINK</span>"
    else
        type_badge="<span class=\"status-badge badge-pending\">DIR</span>"
    fi

    PROJECT_ROWS+="<tr data-tip=\"${proj_name} -> ${proj_source}\">
      <td class=\"name\">${proj_name}</td>
      <td>${proj_vol}</td>
      <td>${type_badge}</td>
      <td><span class=\"status-badge ${status_class}\">${status_text}</span></td>
    </tr>"
done < <(echo "$DEVDRIVE_DATA" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data.get('projects', []):
    print(json.dumps(p))
" 2>/dev/null)

# Mount status display
if [[ "$MOUNTED" == "true" ]]; then
    MOUNT_STATUS="Mounted"
    MOUNT_STATUS_CLASS="good"
else
    MOUNT_STATUS="Not Mounted"
    MOUNT_STATUS_CLASS="danger"
    MOUNT_SIZE="--"
    MOUNT_FREE="--"
fi

python3 -c "
theme = open('$LFG_DIR/lib/theme.css').read()
uijs = open('$LFG_DIR/lib/ui.js').read()
volume_rows = '''$VOLUME_ROWS'''
project_rows = '''$PROJECT_ROWS'''

volumes_html = ''
if volume_rows.strip():
    volumes_html = '<div class=\"section-title\" style=\"color:#c084fc\">Devdrive Volumes</div><table><thead><tr><th>Volume</th><th>Mount Point</th><th class=\"r\">Total</th><th class=\"r\">Free</th><th>FS</th><th class=\"r\">Projects</th></tr></thead><tbody>' + volume_rows + '</tbody></table>'
else:
    volumes_html = '<div class=\"section-title\" style=\"color:#c084fc\">Devdrive Volumes</div><div class=\"empty-state\">No devdrive volumes detected. Attach an external drive with a 900DEVELOPER directory.</div>'

projects_html = ''
if project_rows.strip():
    projects_html = '<div class=\"section-title\" style=\"color:#c084fc\">Symlink Forest</div><table><thead><tr><th>Project</th><th>Volume</th><th>Type</th><th>Status</th></tr></thead><tbody>' + project_rows + '</tbody></table>'
else:
    projects_html = '<div class=\"section-title\" style=\"color:#c084fc\">Symlink Forest</div><div class=\"empty-state\">No projects in symlink forest. Mount devdrive and run sync.</div>'

html = '''<!DOCTYPE html>
<html><head><meta charset=\"utf-8\">
<style>''' + theme + '''
.guidance { border-left-color: #c084fc; }
</style>
</head><body>
  <div class=\"header\">
    <h1><span class=\"brand\">lfg</span> devdrive <span class=\"dim\">Developer Drive</span></h1>
    <span class=\"meta\">$TIMESTAMP</span>
  </div>
  <div class=\"summary\">
    <div class=\"stat\" data-tip=\"Mount status of $MOUNT_POINT\"><span class=\"label\">Status</span><span class=\"value $MOUNT_STATUS_CLASS\">$MOUNT_STATUS</span></div>
    <div class=\"stat\" data-tip=\"Devdrive volumes with 900DEVELOPER\"><span class=\"label\">Volumes</span><span class=\"value\">$VOLUME_COUNT</span></div>
    <div class=\"stat\" data-tip=\"Total projects in symlink forest\"><span class=\"label\">Projects</span><span class=\"value accent\">$PROJECT_COUNT</span></div>
    <div class=\"stat\" data-tip=\"Healthy symlinks\"><span class=\"label\">Healthy</span><span class=\"value good\">$HEALTHY_COUNT</span></div>
    <div class=\"stat\" data-tip=\"Broken symlinks\"><span class=\"label\">Broken</span><span class=\"value''' + (' danger' if $BROKEN_COUNT > 0 else '') + '''\">$BROKEN_COUNT</span></div>
  </div>
  <div class=\"guidance\">
    <strong>DEVDRIVE</strong> manages the unified symlink forest at <code>$MOUNT_POINT</code>.
    Projects from multiple external volumes are linked into a single view.
    Run <code>lfg devdrive sync</code> to rebuild links, or <code>lfg devdrive verify</code> to audit health.
  </div>
  ''' + volumes_html + '''
  ''' + projects_html + '''
  <div id=\"action-bar\"></div>
  <div class=\"footer\">lfg devdrive - Local File Guardian | Developer Drive</div>
  <script>''' + uijs + '''
  LFG.init({ module: \"devdrive\", context: \"Developer Drive\", moduleVersion: \"1.0.0\", welcome: \"$PROJECT_COUNT projects across $VOLUME_COUNT volumes\" });
  document.getElementById(\"action-bar\").appendChild(
    LFG.createCommandPanel(\"DEVDRIVE Actions\", [
      { label: \"Mount\", desc: \"Attach sparse image\", cli: \"lfg devdrive mount\", module: \"devdrive\", action: \"run\", args: \"mount\", color: \"#c084fc\" },
      { label: \"Unmount\", desc: \"Safely eject devdrive\", cli: \"lfg devdrive unmount\", module: \"devdrive\", action: \"run\", args: \"unmount\", color: \"#c084fc\" },
      { label: \"Sync Forest\", desc: \"Rebuild symlink forest\", cli: \"lfg devdrive sync\", module: \"devdrive\", action: \"run\", args: \"sync\", color: \"#c084fc\" },
      { label: \"Verify Links\", desc: \"Audit symlink health\", cli: \"lfg devdrive verify\", module: \"devdrive\", action: \"run\", args: \"verify\", color: \"#c084fc\" },
      { label: \"Create Project\", desc: \"New project on devdrive\", cli: \"lfg devdrive create NAME\", module: \"devdrive\", action: \"run\", args: \"create\", color: \"#c084fc\" },
    ])
  );
  document.getElementById(\"action-bar\").appendChild(
    LFG.createActionBar([
      { label: \"Disk Usage\", color: \"#4a9eff\", onclick: function(){ LFG._postNav('navigate', {target:'wtfs'}); }, tip: \"Navigate to WTFS\" },
      { label: \"Clean Caches\", color: \"#ff8c42\", onclick: function(){ LFG._postNav('navigate', {target:'dtf'}); }, tip: \"Navigate to DTF\" },
      { label: \"View Backups\", color: \"#06d6a0\", onclick: function(){ LFG._postNav('navigate', {target:'btau'}); }, tip: \"Navigate to BTAU\" },
      { label: \"Full Dashboard\", color: \"#4a9eff\", onclick: function(){ LFG._postNav('navigate', {target:'dashboard'}); }, tip: \"Navigate to Dashboard\" },
    ])
  );
  </script>
</body></html>'''

open('$HTML_FILE', 'w').write(html)
"

lfg_state_done devdrive "volume_count=$VOLUME_COUNT" "project_count=$PROJECT_COUNT" "healthy=$HEALTHY_COUNT" "broken=$BROKEN_COUNT"

if [[ "${LFG_NO_VIEWER:-}" == "1" ]]; then
    echo "Done (headless)."
else
    CHAIN_FILE="/tmp/.lfg_chain_$$"
    echo "Opening viewer..."
    "$VIEWER" "$HTML_FILE" "LFG DEVDRIVE - Developer Drive" --select "$CHAIN_FILE" &
    VPID=$!
    disown
    (
      while kill -0 "$VPID" 2>/dev/null; do
        if [[ -s "$CHAIN_FILE" ]]; then
          SEL=$(cat "$CHAIN_FILE"); rm -f "$CHAIN_FILE"
          case "$SEL" in
            wtfs) "$LFG_DIR/lib/scan.sh" ;; dtf) "$LFG_DIR/lib/clean.sh" ;; btau) "$LFG_DIR/lib/btau.sh" --view ;; dashboard) "$LFG_DIR/lib/dashboard.sh" ;;
          esac; break
        fi; sleep 0.3
      done; rm -f "$CHAIN_FILE"
    ) &
    disown
    echo "Done."
fi

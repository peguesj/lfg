#!/usr/bin/env bash
# =============================================================================
# devdrive-quickactions.sh — Install Finder Quick Actions for LFG DEVDRIVE
# =============================================================================
# Creates Automator Quick Action (.workflow) bundles in ~/Library/Services/
# for common DEVDRIVE operations accessible from Finder's right-click menu.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LFG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$LFG_DIR/lib/state.sh"
LFG_MODULE="devdrive-quickactions"

SERVICES_DIR="$HOME/Library/Services"
mkdir -p "$SERVICES_DIR" 2>/dev/null

INSTALLED=0
SKIPPED=0

# Helper: create a Quick Action workflow bundle
# Args: $1=workflow name, $2=shell script body, $3=input type (files/text/none), $4=description
create_workflow() {
    local name="$1"
    local script_body="$2"
    local input_type="${3:-files}"
    local description="${4:-}"
    local workflow_dir="$SERVICES_DIR/${name}.workflow"
    local contents_dir="$workflow_dir/Contents"

    # Skip if already installed (use --force to override)
    if [[ -d "$workflow_dir" ]] && [[ "${FORCE:-}" != "true" ]]; then
        echo "  SKIP: '$name' already installed (use --force to reinstall)"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    rm -rf "$workflow_dir"
    mkdir -p "$contents_dir"

    # Determine input type settings for Automator
    local wf_input_class="NSFilenamesPboardType"
    local wf_type_ids='<string>com.apple.cocoa.path</string>'
    local wf_service_input="filenames"
    if [[ "$input_type" == "none" ]]; then
        wf_input_class="NSStringPboardType"
        wf_type_ids='<string>com.apple.cocoa.string</string>'
        wf_service_input="nothing"
    fi

    # Escape XML special characters in script body
    local escaped_script
    escaped_script=$(python3 -c "
import sys, html
script = sys.stdin.read()
print(html.escape(script))
" <<< "$script_body")

    # Write document.wflow (Automator workflow definition)
    cat > "$contents_dir/document.wflow" << WFLOW_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AMApplicationBuild</key>
	<string>523</string>
	<key>AMApplicationVersion</key>
	<string>2.10</string>
	<key>AMDocumentVersion</key>
	<string>2</string>
	<key>actions</key>
	<array>
		<dict>
			<key>action</key>
			<dict>
				<key>AMAccepts</key>
				<dict>
					<key>Container</key>
					<string>List</string>
					<key>Optional</key>
					<true/>
					<key>Types</key>
					<array>
						${wf_type_ids}
					</array>
				</dict>
				<key>AMActionVersion</key>
				<string>1.0.2</string>
				<key>AMApplication</key>
				<array>
					<string>Automator</string>
				</array>
				<key>AMCategory</key>
				<string>AMCategoryUtilities</string>
				<key>AMIconName</key>
				<string>Automator</string>
				<key>AMKeywords</key>
				<array>
					<string>Shell</string>
					<string>Script</string>
					<string>LFG</string>
				</array>
				<key>AMName</key>
				<string>Run Shell Script</string>
				<key>AMProvides</key>
				<dict>
					<key>Container</key>
					<string>List</string>
					<key>Types</key>
					<array>
						<string>com.apple.cocoa.string</string>
					</array>
				</dict>
				<key>AMRequiredResources</key>
				<array/>
				<key>ActionBundlePath</key>
				<string>/System/Library/Automator/Run Shell Script.action</string>
				<key>ActionName</key>
				<string>Run Shell Script</string>
				<key>ActionParameters</key>
				<dict>
					<key>COMMAND_STRING</key>
					<string>${escaped_script}</string>
					<key>CheckedForUserDefaultShell</key>
					<true/>
					<key>inputMethod</key>
					<integer>1</integer>
					<key>shell</key>
					<string>/bin/bash</string>
					<key>source</key>
					<string></string>
				</dict>
				<key>BundleIdentifier</key>
				<string>com.apple.RunShellScript</string>
				<key>CFBundleVersion</key>
				<string>1.0.2</string>
				<key>CanShowSelectedItemsWhenRun</key>
				<false/>
				<key>CanShowWhenRun</key>
				<true/>
				<key>Category</key>
				<array>
					<string>AMCategoryUtilities</string>
				</array>
				<key>Class Name</key>
				<string>RunShellScriptAction</string>
				<key>InputUUID</key>
				<string>$(uuidgen)</string>
				<key>Keywords</key>
				<array>
					<string>Shell</string>
					<string>Script</string>
				</array>
				<key>OutputUUID</key>
				<string>$(uuidgen)</string>
				<key>UUID</key>
				<string>$(uuidgen)</string>
				<key>UnlocalizedApplications</key>
				<array>
					<string>Automator</string>
				</array>
			</dict>
		</dict>
	</array>
	<key>connectors</key>
	<dict/>
	<key>workflowMetaData</key>
	<dict>
		<key>workflowTypeIdentifier</key>
		<string>com.apple.Automator.servicesMenu</string>
	</dict>
</dict>
</plist>
WFLOW_EOF

    # Write Info.plist
    cat > "$contents_dir/Info.plist" << INFO_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>${name}</string>
	<key>CFBundleIdentifier</key>
	<string>io.lfg.quickaction.$(echo "$name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSMenuItem</key>
			<dict>
				<key>default</key>
				<string>${name}</string>
			</dict>
			<key>NSMessage</key>
			<string>runWorkflowAsService</string>
			<key>NSSendTypes</key>
			<array>
				<string>${wf_input_class}</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
INFO_EOF

    echo "  Installed: $workflow_dir"
    INSTALLED=$((INSTALLED + 1))
    return 0
}

# --- Quick Action Definitions ---

echo "=== LFG DEVDRIVE Finder Quick Actions ==="
echo ""

# Parse --force flag
FORCE="false"
for arg in "$@"; do
    [[ "$arg" == "--force" ]] && FORCE="true"
done

# 1. Sync to DEVDRIVE
echo "[Sync to DEVDRIVE]"
create_workflow "LFG Sync to DEVDRIVE" '#!/bin/bash
# LFG Quick Action: Sync folder to DEVDRIVE
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
LFG_BIN="$HOME/tools/@yj/lfg/lfg"

for f in "$@"; do
    if [ -d "$f" ]; then
        "$LFG_BIN" devdrive sync 2>&1 | osascript -e "
            on run argv
                display notification (item 1 of argv) with title \"LFG DEVDRIVE\" subtitle \"Sync Complete\"
            end run" -- "$(cat)"
    fi
done
' "files" "Sync selected folder to DEVDRIVE volume"
echo ""

# 2. Protect from DTF
echo "[Protect from DTF]"
create_workflow "LFG Protect from DTF" '#!/bin/bash
# LFG Quick Action: Protect folder from DTF cleanup
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
LFG_BIN="$HOME/tools/@yj/lfg/lfg"

for f in "$@"; do
    if [ -d "$f" ]; then
        "$LFG_BIN" inbox send --type dtf-protect --path "$f" 2>&1
        osascript -e "display notification \"Protected: $(basename "$f")\" with title \"LFG DTF\" subtitle \"Path Protected\""
    fi
done
' "files" "Protect selected folder from DTF cleanup"
echo ""

# 3. DEVDRIVE Status
echo "[DEVDRIVE Status]"
create_workflow "LFG DEVDRIVE Status" '#!/bin/bash
# LFG Quick Action: Show DEVDRIVE status viewer
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
LFG_BIN="$HOME/tools/@yj/lfg/lfg"

"$LFG_BIN" devdrive 2>&1
' "none" "Open LFG DEVDRIVE status viewer"
echo ""

# 4. Mount All DEVDRIVE Volumes
echo "[Mount All Volumes]"
create_workflow "LFG Mount All Volumes" '#!/bin/bash
# LFG Quick Action: Mount all DEVDRIVE sparse images
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
AUTOMOUNT="$HOME/tools/@yj/lfg/scripts/devdrive-automount.sh"

if [ -f "$AUTOMOUNT" ]; then
    bash "$AUTOMOUNT" 2>&1
    osascript -e "display notification \"All DEVDRIVE volumes mounted\" with title \"LFG\" subtitle \"Mount Complete\""
else
    osascript -e "display notification \"Automount script not found\" with title \"LFG\" subtitle \"Error\""
fi
' "none" "Mount all DEVDRIVE sparse image volumes"
echo ""

# 5. Unmount All DEVDRIVE Volumes
echo "[Unmount All Volumes]"
create_workflow "LFG Unmount All Volumes" '#!/bin/bash
# LFG Quick Action: Safely unmount all DEVDRIVE volumes
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

unmounted=0
for vol in /Volumes/DDRV* /Volumes/YJ_MORE; do
    if [ -d "$vol" ]; then
        hdiutil detach "$vol" 2>/dev/null && unmounted=$((unmounted + 1))
    fi
done

osascript -e "display notification \"Unmounted $unmounted volume(s)\" with title \"LFG\" subtitle \"Unmount Complete\""
' "none" "Safely unmount all DEVDRIVE volumes"
echo ""

echo "=== Done: $INSTALLED installed, $SKIPPED already exist ==="
echo ""
echo "Quick Actions are available in Finder's right-click menu under 'Quick Actions'."
echo "If they do not appear, go to: System Settings > Privacy & Security > Extensions > Finder"

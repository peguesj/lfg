# LFG - Local File Guardian
# Build macOS app bundles for viewer and menubar

SWIFT := swiftc -O
VIEWER_APP := LFG.app
MENUBAR_APP := LFG Menubar.app
ICNS := assets/brand/AppIcon.icns

.PHONY: all clean icons

all:
	@echo "── Building LFG Viewer ──"
	@$(MAKE) --no-print-directory viewer-app
	@echo "── Building LFG Menubar ──"
	@$(MAKE) --no-print-directory menubar-app
	@echo "── All targets built ──"

.PHONY: viewer-app menubar-app

# --- Icon Generation ---
icons: $(ICNS)

$(ICNS): assets/brand/lfg-icon.svg scripts/gen-icns.sh
	bash scripts/gen-icns.sh

# --- Viewer App Bundle ---
viewer-app: viewer.swift Info.plist $(ICNS)
	@mkdir -p "$(VIEWER_APP)/Contents/MacOS" "$(VIEWER_APP)/Contents/Resources"
	$(SWIFT) -o "$(VIEWER_APP)/Contents/MacOS/LFG" viewer.swift \
		-framework Cocoa -framework WebKit
	cp Info.plist "$(VIEWER_APP)/Contents/Info.plist"
	cp $(ICNS) "$(VIEWER_APP)/Contents/Resources/AppIcon.icns"
	@# Backward-compat symlink so old paths still work
	@ln -sf "$(VIEWER_APP)/Contents/MacOS/LFG" viewer
	@echo "  → LFG.app ready"

# --- Menubar App Bundle ---
menubar-app: menubar.swift InfoMenubar.plist $(ICNS)
	@mkdir -p "$(MENUBAR_APP)/Contents/MacOS" "$(MENUBAR_APP)/Contents/Resources"
	$(SWIFT) -o "$(MENUBAR_APP)/Contents/MacOS/LFG Menubar" menubar.swift \
		-framework Cocoa -framework UserNotifications
	cp InfoMenubar.plist "$(MENUBAR_APP)/Contents/Info.plist"
	cp $(ICNS) "$(MENUBAR_APP)/Contents/Resources/AppIcon.icns"
	@# Backward-compat symlink
	@ln -sf "$(MENUBAR_APP)/Contents/MacOS/LFG Menubar" lfg-menubar
	@echo "  → LFG Menubar.app ready"

clean:
	@echo "── Clean ──"
	rm -rf "$(VIEWER_APP)" "$(MENUBAR_APP)"
	rm -f viewer lfg-menubar
	rm -f $(ICNS)

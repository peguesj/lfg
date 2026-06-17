# LFG - Local File Guardian
# Build macOS app bundles

SWIFT := swiftc -O
LFG_APP := LFG.app
MENUBAR_APP := LFG Helper.app
ICNS := assets/brand/AppIcon.icns
SPM_RELEASE := .build/release

.PHONY: all clean icons

all:
	@echo "── Building LFG App (v3 SPM) ──"
	@$(MAKE) --no-print-directory lfg-app
	@echo "── All targets built ──"

.PHONY: lfg-app viewer-app menubar-app

# --- Icon Generation ---
icons: $(ICNS)

$(ICNS): assets/brand/lfg-icon.svg scripts/gen-icns.sh
	bash scripts/gen-icns.sh

# --- LFG App Bundle (v3 SwiftUI, SPM-built) ---
# Bundles Sources/LFGApp (SwiftUI @main) with MenuBarExtra + main window.
# Replaces both the old viewer-app and menubar-app targets.
lfg-app: Sources/LFGApp/LFGInfo.plist $(ICNS)
	swift build -c release --product LFGApp
	@rm -rf "$(LFG_APP)"
	@mkdir -p "$(LFG_APP)/Contents/MacOS" "$(LFG_APP)/Contents/Resources"
	cp "$(SPM_RELEASE)/LFGApp" "$(LFG_APP)/Contents/MacOS/LFG"
	@chmod +x "$(LFG_APP)/Contents/MacOS/LFG"
	cp Sources/LFGApp/LFGInfo.plist "$(LFG_APP)/Contents/Info.plist"
	cp $(ICNS) "$(LFG_APP)/Contents/Resources/AppIcon.icns"
	@echo "  → LFG.app ready (v3)"

# --- Legacy targets (kept for reference, not built by default) ---
viewer-app: viewer.swift Info.plist $(ICNS)
	@mkdir -p "$(LFG_APP)/Contents/MacOS" "$(LFG_APP)/Contents/Resources"
	$(SWIFT) -o "$(LFG_APP)/Contents/MacOS/LFG" viewer.swift \
		-framework Cocoa -framework WebKit -framework Security
	cp Info.plist "$(LFG_APP)/Contents/Info.plist"
	cp $(ICNS) "$(LFG_APP)/Contents/Resources/AppIcon.icns"
	@ln -sf "$(LFG_APP)/Contents/MacOS/LFG" viewer
	@echo "  → LFG.app (legacy viewer) ready"

menubar-app: menubar.swift InfoMenubar.plist $(ICNS)
	@mkdir -p "$(MENUBAR_APP)/Contents/MacOS" "$(MENUBAR_APP)/Contents/Resources"
	$(SWIFT) -o "$(MENUBAR_APP)/Contents/MacOS/LFG Helper" menubar.swift \
		-framework Cocoa -framework WebKit -framework UserNotifications -framework Security -framework ServiceManagement
	cp InfoMenubar.plist "$(MENUBAR_APP)/Contents/Info.plist"
	cp $(ICNS) "$(MENUBAR_APP)/Contents/Resources/AppIcon.icns"
	@ln -sf "$(MENUBAR_APP)/Contents/MacOS/LFG Helper" lfg-menubar
	@echo "  → LFG Helper.app (legacy menubar) ready"

clean:
	@echo "── Clean ──"
	rm -rf "$(LFG_APP)" "$(MENUBAR_APP)"
	rm -f viewer lfg-menubar
	rm -f $(ICNS)

.PHONY: pkg
pkg:
	@echo "── Building .pkg installer ──"
	bash pkg-build/build.sh

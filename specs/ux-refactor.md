# Spec: UX Refactor — Native SwiftUI Module Views

## Purpose
Replace the WebKit-based HTML viewer (`viewer.swift`, `.lfg_*.html`) with native SwiftUI views for each LFG module. Each module gets a dedicated View backed by a ViewModel in LFGKit. Design tokens enforce consistent spacing, color, and typography across all views.

---

## Design Tokens (Sources/LFGKit/DesignSystem/)

### Colors (`LFGColors.swift`)
```swift
extension Color {
    static let lfgBackground   = Color("LFGBackground")    // #1A1A1A dark / #F5F5F5 light
    static let lfgSurface      = Color("LFGSurface")       // #242424 / #FFFFFF
    static let lfgAccent       = Color("LFGAccent")        // #00C8FF
    static let lfgWarning      = Color("LFGWarning")       // #FFB800
    static let lfgDanger       = Color("LFGDanger")        // #FF3B30
    static let lfgSuccess      = Color("LFGSuccess")       // #34C759
    static let lfgTextPrimary  = Color("LFGTextPrimary")
    static let lfgTextSecondary = Color("LFGTextSecondary")
}
```
Colors defined in `Sources/LFGApp/Assets.xcassets` with light/dark variants.

### Spacing (`LFGSpacing.swift`)
```swift
enum LFGSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 40
}
```

### Typography (`LFGTypography.swift`)
```swift
extension Font {
    static let lfgTitle    = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let lfgHeadline = Font.system(size: 15, weight: .medium,   design: .default)
    static let lfgBody     = Font.system(size: 13, weight: .regular,  design: .default)
    static let lfgMono     = Font.system(size: 12, weight: .regular,  design: .monospaced)
    static let lfgCaption  = Font.system(size: 11, weight: .regular,  design: .default)
}
```

---

## Module Views

### 1. WTFSView — Disk Usage Analysis
**Replaces**: `.lfg_scan.html`
- Top-level disk usage ring chart (SwiftUI Canvas, not WebKit)
- Expandable tree: directory rows sorted by size descending
- Row: icon (SF Symbol by file type), name, size bar, size label
- Filter bar: min size slider, extension filter chips
- Actions: "Open in Finder", "Move to Trash" (with confirmation)
- ViewModel: `WTFSViewModel` — runs `du` async, publishes `[DiskNode]`

### 2. DTFView — Cache Cleanup
**Replaces**: `.lfg_clean.html`
- Category list: Xcode derived data, npm cache, pip cache, CocoaPods, brew, OS caches
- Per-category: size estimate badge, checkbox to include in cleanup
- "Scan" button → async scan publishes `[CacheCategory]`
- "Clean Selected" button → confirmation sheet listing bytes to reclaim
- Progress bar during delete; summary card on completion
- ViewModel: `DTFViewModel` — wraps `lib/clean.sh` logic in Swift async

### 3. BTAUView — Backup Lifecycle
**Replaces**: part of `.lfg_dashboard.html`
- List of BTAU backup jobs from `~/.config/lfg/btau.json`
- Per-job: last run, next scheduled, status badge, archive size
- Actions: Run Now, Skip, View Log
- New Job sheet: source path picker, destination (DevDrive volume), schedule picker (hourly/daily/weekly)
- ViewModel: `BTAUViewModel`

### 4. DevDriveView — Volume Manager
**Replaces**: `.lfg_devdrive.html`
Already specified in `native-app-operations.md`. This view IS the DevDrive module view.
Re-exported from `LFGApp.DevDriveView`.

### 5. SSDView — Spotlight Index Manager
**Replaces**: bespoke HTML
- List of volumes with Spotlight indexing status
- Toggle per volume: enable/disable indexing (wraps `mdutil -i on/off`)
- "Rebuild Index" button with confirmation
- Index size estimate per volume
- ViewModel: `SSDViewModel` — parses `mdutil -s` output

---

## Navigation Structure

`LFGApp` uses a `NavigationSplitView`:
- Sidebar: module list (WTFS, DTF, BTAU, DevDrive, SSD, Settings)
- Detail: selected module view
- Toolbar: primary action for current module + global "Reconcile" button

Module rows in sidebar show a live status indicator (colored dot) updated every 30 seconds.

---

## Toolbar Pattern (per module)

Each module view uses a consistent `ToolbarItemGroup(placement: .primaryAction)`:
1. Primary action button (e.g., "Scan", "Clean", "Mount All")
2. Secondary action menu (kebab icon) with destructive actions
3. Refresh button (circular arrow SF Symbol)

---

## Removal Plan
After all module views are verified in Wave 5:
- Delete `viewer.swift`, `menubar.swift` WebKit-based implementations
- Remove `.lfg_*.html` static files
- Remove `LFG.app/` and `LFG Helper.app/` binary bundles (replaced by SPM-built products)
- Keep `lib/*.sh` and `devdrive/*.py` as backend invocation layer

---

## TDD Requirements

### Unit tests (Tests/LFGKitTests/)
- `WTFSViewModelTests`: feed mock `du` output; assert `[DiskNode]` tree structure correct
- `DTFViewModelTests`: mock cache directories; assert category sizes computed correctly
- `SSDViewModelTests`: mock `mdutil -s` output; assert indexing status parsed per volume
- `DesignTokenTests`: assert all color/spacing/font constants are non-nil at runtime (catches missing asset catalog entries)

### Coverage target
80% line coverage on all ViewModel types in `Sources/LFGKit/`.

## Acceptance Criteria
- All 5 module views render without crash on macOS 14 and 15
- No `WKWebView` import anywhere in `Sources/`
- Sidebar navigation switches views without memory leak (verified via Instruments in Wave 6)
- Design token colors render correctly in both light and dark mode

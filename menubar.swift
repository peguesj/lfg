import Cocoa

// =============================================================================
// LFG Menubar v2 - Status monitor with actions, disk graph, notifications
// =============================================================================
// Watches ~/.config/lfg/state.json for module state changes.
// Provides actionable submenus for each module, disk usage sparkline,
// and sends notifications via osascript on state transitions.
// =============================================================================

// MARK: - Disk Graph View (custom NSView for menu item)

class DiskGraphView: NSView {
    var dataPoints: [(free: Double, used: Double, timestamp: String)] = []
    let maxPoints = 24
    let graphHeight: CGFloat = 48
    let graphWidth: CGFloat = 280
    let barWidth: CGFloat = 8
    let barGap: CGFloat = 3

    override var intrinsicContentSize: NSSize {
        return NSSize(width: graphWidth + 20, height: graphHeight + 36)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let pad: CGFloat = 10
        let top: CGFloat = 20
        let w = bounds.width - pad * 2
        let h = graphHeight

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        ("DISK USAGE" as NSString).draw(at: NSPoint(x: pad, y: bounds.height - 14), withAttributes: titleAttrs)

        // Background
        ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        let bgRect = CGRect(x: pad, y: top, width: w, height: h)
        ctx.fill(bgRect)

        guard !dataPoints.isEmpty else {
            let emptyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            ("No data yet" as NSString).draw(at: NSPoint(x: pad + 8, y: top + h/2 - 6), withAttributes: emptyAttrs)
            return
        }

        let count = min(dataPoints.count, maxPoints)
        let recent = Array(dataPoints.suffix(count))
        let totalW = barWidth + barGap
        let startX = pad + w - CGFloat(count) * totalW

        for (i, dp) in recent.enumerated() {
            let x = startX + CGFloat(i) * totalW
            let usedPct = dp.used / 100.0
            let barH = CGFloat(usedPct) * h

            // Used portion
            let usedColor: NSColor
            if usedPct > 0.90 { usedColor = NSColor(red: 1, green: 0.3, blue: 0.42, alpha: 0.8) }
            else if usedPct > 0.80 { usedColor = NSColor(red: 1, green: 0.55, blue: 0.26, alpha: 0.8) }
            else if usedPct > 0.70 { usedColor = NSColor(red: 1, green: 0.82, blue: 0.4, alpha: 0.8) }
            else { usedColor = NSColor(red: 0.02, green: 0.84, blue: 0.63, alpha: 0.8) }

            ctx.setFillColor(usedColor.cgColor)
            ctx.fill(CGRect(x: x, y: top, width: barWidth, height: barH))

            // Free portion
            ctx.setFillColor(NSColor(red: 0.29, green: 0.62, blue: 1, alpha: 0.3).cgColor)
            ctx.fill(CGRect(x: x, y: top + barH, width: barWidth, height: h - barH))
        }

        // Current value label
        if let last = recent.last {
            let valStr = String(format: "%.0f%% used", last.used)
            let valAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            (valStr as NSString).draw(at: NSPoint(x: pad + 2, y: 4), withAttributes: valAttrs)

            let freeStr = String(format: "Free: %@", dataPoints.last?.timestamp ?? "?")
            (freeStr as NSString).draw(at: NSPoint(x: pad + w - 100, y: 4), withAttributes: valAttrs)
        }
    }
}

// MARK: - Main Application

class LFGMenubar: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var refreshTimer: Timer?
    var graphTimer: Timer?
    var fileWatchSource: DispatchSourceFileSystemObject?
    var previousState: [String: Any] = [:]

    let stateFile = NSHomeDirectory() + "/.config/lfg/state.json"
    let historyFile = NSHomeDirectory() + "/.config/lfg/disk_history.json"
    let lfgPath = NSHomeDirectory() + "/tools/@yj/lfg/lfg"

    // Live stats
    var diskFree = "..."
    var diskUsed = "..."
    var diskUsedPct: Double = 0

    // Disk history for graph
    var diskHistory: [(free: Double, used: Double, timestamp: String)] = []
    let diskGraphView = DiskGraphView()

    // Graph refresh interval (seconds)
    var graphInterval: TimeInterval = 300  // 5 minutes

    // Module state
    struct ModuleState {
        var status: String = "idle"
        var lastResult: String = ""
        var updatedAt: String = ""
    }
    var modules: [String: ModuleState] = [
        "wtfs": ModuleState(),
        "dtf": ModuleState(),
        "btau": ModuleState(),
        "devdrive": ModuleState(),
        "stfu": ModuleState(),
    ]

    // Devdrive config state
    var devdriveMountMode: String = "..."
    var devdriveAutoMoveEnabled: Bool = false
    var devdriveAutoMoveLastCount: Int = 0

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "LFG ..."
            button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        }

        loadDiskHistory()
        loadState()
        buildMenu()
        startFileWatcher()

        // Periodic disk stats refresh (60s)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshStats()
        }

        // Disk graph data collection
        graphTimer = Timer.scheduledTimer(withTimeInterval: graphInterval, repeats: true) { [weak self] _ in
            self?.recordDiskDataPoint()
        }

        refreshStats()
        refreshDevdriveConfig()
        recordDiskDataPoint()
        sendNotification(title: "LFG Menubar", body: "Monitoring active")
    }

    // MARK: - State Management

    func loadState() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        diskFree = json["disk_free"] as? String ?? "?"
        diskUsed = json["disk_used"] as? String ?? "?"

        if let mods = json["modules"] as? [String: [String: Any]] {
            for (name, info) in mods {
                let status = info["status"] as? String ?? "idle"
                let updated = info["updated_at"] as? String ?? ""

                let prev = modules[name]?.status ?? "idle"
                if prev == "running" && status == "completed" {
                    let result = buildResultSummary(name: name, info: info)
                    sendNotification(title: "LFG \(name.uppercased())", body: result)
                } else if prev == "running" && status == "error" {
                    let err = info["error"] as? String ?? "Unknown error"
                    sendNotification(title: "LFG \(name.uppercased()) Error", body: err)
                } else if prev != "running" && status == "running" {
                    sendNotification(title: "LFG \(name.uppercased())", body: "Running...")
                }

                modules[name] = ModuleState(
                    status: status,
                    lastResult: buildResultSummary(name: name, info: info),
                    updatedAt: updated
                )
            }
        }

        previousState = json
    }

    func buildResultSummary(name: String, info: [String: Any]) -> String {
        switch name {
        case "wtfs":
            let total = info["total_size"] as? String ?? "?"
            let dirs = info["dir_count"] as? String ?? "?"
            return "\(total) across \(dirs) dirs"
        case "dtf":
            let amount = info["reclaimable"] as? String ?? info["freed"] as? String ?? "?"
            let mode = info["mode"] as? String ?? "scan"
            return mode == "force" ? "Freed \(amount)" : "\(amount) reclaimable"
        case "btau":
            let count = info["backup_count"] as? String ?? "0"
            return "\(count) backups"
        case "devdrive":
            let vols = info["volume_count"] as? String ?? "0"
            let projs = info["project_count"] as? String ?? "0"
            return "\(projs) projects, \(vols) volumes"
        case "stfu":
            let projects = info["projects"] as? String ?? "?"
            let dupes = info["dupes"] as? String ?? "0"
            let savings = info["savings"] as? String ?? "0"
            return "\(projects) projects, \(dupes) dupes, \(savings)"
        default:
            return info["status"] as? String ?? "?"
        }
    }

    // MARK: - Disk History (for graph)

    func loadDiskHistory() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: historyFile)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        diskHistory = arr.compactMap { entry in
            guard let free = entry["free"] as? Double,
                  let used = entry["used"] as? Double,
                  let ts = entry["timestamp"] as? String else { return nil }
            return (free: free, used: used, timestamp: ts)
        }
    }

    func saveDiskHistory() {
        let arr = diskHistory.map { ["free": $0.free, "used": $0.used, "timestamp": $0.timestamp] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: []) else { return }
        try? data.write(to: URL(fileURLWithPath: historyFile))
    }

    func recordDiskDataPoint() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let raw = Self.shell("df / | awk 'NR==2{print $3 \"|\" $4 \"|\" $5}'")
            let parts = raw.split(separator: "|")
            guard parts.count >= 3 else { return }
            // $3=used blocks, $4=available blocks, $5=capacity%
            let pctStr = String(parts[2]).replacingOccurrences(of: "%", with: "")
            let usedPct = Double(pctStr) ?? 0
            let freeBlocks = Double(String(parts[1])) ?? 0
            let freeGB = freeBlocks * 512 / 1_073_741_824  // 512-byte blocks -> GB

            let ts = Self.shell("date '+%H:%M'")

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.diskUsedPct = usedPct
                self.diskHistory.append((free: freeGB, used: usedPct, timestamp: ts))
                // Keep last 24 data points
                if self.diskHistory.count > 24 {
                    self.diskHistory = Array(self.diskHistory.suffix(24))
                }
                self.saveDiskHistory()
                self.diskGraphView.dataPoints = self.diskHistory
                self.diskGraphView.needsDisplay = true
            }
        }
    }

    // MARK: - File Watcher

    func startFileWatcher() {
        if !FileManager.default.fileExists(atPath: stateFile) {
            try? "{}".write(toFile: stateFile, atomically: true, encoding: .utf8)
        }

        let fd = open(stateFile, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.loadState()
            self?.buildMenu()
            self?.updateTitle()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatchSource = source
    }

    // MARK: - Menu Construction

    func buildMenu() {
        menu = NSMenu()

        // Header
        let header = NSMenuItem(title: "LFG - Local File Guardian", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: "LFG - Local File Guardian",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)]
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // Disk stats
        menu.addItem(makeStatItem("Disk Free", value: diskFree, color: .systemBlue))
        menu.addItem(makeStatItem("Disk Used", value: diskUsed, color: diskUsedPct > 90 ? .systemRed : .secondaryLabelColor))
        menu.addItem(NSMenuItem.separator())

        // Disk graph
        let graphItem = NSMenuItem()
        diskGraphView.frame = NSRect(x: 0, y: 0, width: 300, height: 84)
        diskGraphView.dataPoints = diskHistory
        graphItem.view = diskGraphView
        menu.addItem(graphItem)
        menu.addItem(NSMenuItem.separator())

        // Module status section
        for (name, mod) in modules.sorted(by: { $0.key < $1.key }) {
            let icon: String
            let color: NSColor
            switch mod.status {
            case "running":
                icon = "\u{25B6}"
                color = .systemYellow
            case "completed":
                icon = "\u{2713}"
                color = .systemGreen
            case "error":
                icon = "\u{2717}"
                color = .systemRed
            default:
                icon = "\u{2022}"
                color = .secondaryLabelColor
            }

            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let attrStr = NSMutableAttributedString()
            attrStr.append(NSAttributedString(string: "\(icon) \(name.uppercased()) ",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                             .foregroundColor: color]))
            if !mod.lastResult.isEmpty {
                attrStr.append(NSAttributedString(string: "- \(mod.lastResult)",
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                 .foregroundColor: NSColor.secondaryLabelColor]))
            }
            item.attributedTitle = attrStr
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // --- WTFS Actions Submenu ---
        let wtfsItem = NSMenuItem(title: "WTFS - Disk Usage", action: nil, keyEquivalent: "")
        let wtfsMenu = NSMenu()
        addSubItem(wtfsMenu, "Scan ~/Developer", action: #selector(wtfsDeveloper), key: "")
        addSubItem(wtfsMenu, "Scan ~/", action: #selector(wtfsHome), key: "")
        addSubItem(wtfsMenu, "Scan /", action: #selector(wtfsRoot), key: "")
        addSubItem(wtfsMenu, "Open Viewer", action: #selector(openWTFS), key: "1")
        wtfsItem.submenu = wtfsMenu
        menu.addItem(wtfsItem)

        // --- DTF Actions Submenu ---
        let dtfItem = NSMenuItem(title: "DTF - Cache Cleanup", action: nil, keyEquivalent: "")
        let dtfMenu = NSMenu()
        addSubItem(dtfMenu, "Scan (Dry Run)", action: #selector(dtfScan), key: "")
        addSubItem(dtfMenu, "Clean All", action: #selector(dtfForce), key: "")
        addSubItem(dtfMenu, "Clean + Docker", action: #selector(dtfForceDocker), key: "")
        addSubItem(dtfMenu, "Clean + Sudo", action: #selector(dtfForceSudo), key: "")
        addSubItem(dtfMenu, "Clean All + Docker + Sudo", action: #selector(dtfNuclear), key: "")
        dtfMenu.addItem(NSMenuItem.separator())
        addSubItem(dtfMenu, "Open Viewer", action: #selector(openDTF), key: "2")
        dtfItem.submenu = dtfMenu
        menu.addItem(dtfItem)

        // --- BTAU Actions Submenu ---
        let btauItem = NSMenuItem(title: "BTAU - Backups", action: nil, keyEquivalent: "")
        let btauMenu = NSMenu()
        addSubItem(btauMenu, "View Status", action: #selector(openBTAU), key: "3")
        addSubItem(btauMenu, "Discover Volumes", action: #selector(btauDiscover), key: "")
        addSubItem(btauMenu, "Mount Devdrive", action: #selector(btauMount), key: "")
        addSubItem(btauMenu, "Unmount Devdrive", action: #selector(btauUnmount), key: "")
        btauItem.submenu = btauMenu
        menu.addItem(btauItem)

        // --- DEVDRIVE Actions Submenu ---
        let modeLabel = devdriveMountMode == "sparse_to_local" ? "sparse->local" :
                        devdriveMountMode == "local_to_sparse" ? "local->sparse" : devdriveMountMode
        let autoLabel = devdriveAutoMoveEnabled ? "ON" : "OFF"
        let ddItem = NSMenuItem(title: "DEVDRIVE [\(modeLabel)] auto-move:\(autoLabel)", action: nil, keyEquivalent: "")
        let ddMenu = NSMenu()
        addSubItem(ddMenu, "View Status", action: #selector(openDevdrive), key: "4")
        addSubItem(ddMenu, "Mount (\(modeLabel))", action: #selector(ddMount), key: "")
        addSubItem(ddMenu, "Unmount", action: #selector(ddUnmount), key: "")
        addSubItem(ddMenu, "Sync Forest", action: #selector(ddSync), key: "")
        addSubItem(ddMenu, "Verify Links", action: #selector(ddVerify), key: "")
        ddMenu.addItem(NSMenuItem.separator())
        addSubItem(ddMenu, "Show Config", action: #selector(ddConfigShow), key: "")
        addSubItem(ddMenu, "Auto-Move (Dry Run)", action: #selector(ddAutoMoveDry), key: "")
        addSubItem(ddMenu, "Auto-Move (Execute)", action: #selector(ddAutoMoveForce), key: "")
        ddItem.submenu = ddMenu
        menu.addItem(ddItem)

        // --- STFU Actions Submenu ---
        let stfuItem = NSMenuItem(title: "STFU - Source Tree Forensics", action: nil, keyEquivalent: "")
        let stfuMenu = NSMenu()
        addSubItem(stfuMenu, "Full Analysis (Dry Run)", action: #selector(stfuDryRun), key: "")
        addSubItem(stfuMenu, "Full Analysis (Execute)", action: #selector(stfuExecute), key: "")
        stfuMenu.addItem(NSMenuItem.separator())
        addSubItem(stfuMenu, "Dependency Analysis", action: #selector(stfuDeps), key: "")
        addSubItem(stfuMenu, "File Fingerprinting", action: #selector(stfuFingerprint), key: "")
        addSubItem(stfuMenu, "Duplicate Detection", action: #selector(stfuDuplicates), key: "")
        addSubItem(stfuMenu, "Library Candidates", action: #selector(stfuLibraries), key: "")
        addSubItem(stfuMenu, "Environment Groups", action: #selector(stfuEnvs), key: "")
        stfuMenu.addItem(NSMenuItem.separator())
        addSubItem(stfuMenu, "Open Viewer", action: #selector(openSTFU), key: "5")
        stfuItem.submenu = stfuMenu
        menu.addItem(stfuItem)

        // --- AI Actions Submenu ---
        let aiItem = NSMenuItem(title: "AI - Analysis Engine", action: nil, keyEquivalent: "")
        let aiMenu = NSMenu()
        addSubItem(aiMenu, "Show Config", action: #selector(aiConfigShow), key: "")
        addSubItem(aiMenu, "Test Connection", action: #selector(aiTestConnection), key: "")
        aiMenu.addItem(NSMenuItem.separator())
        addSubItem(aiMenu, "Analyze ~/Developer", action: #selector(aiAnalyzeDeveloper), key: "")
        aiItem.submenu = aiMenu
        menu.addItem(aiItem)

        // --- Settings Submenu ---
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()
        addSubItem(settingsMenu, "Show Settings", action: #selector(settingsShow), key: "")
        addSubItem(settingsMenu, "Show Paths", action: #selector(settingsPaths), key: "")
        addSubItem(settingsMenu, "Reset Defaults", action: #selector(settingsReset), key: "")
        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // --- Graph Interval Submenu ---
        let intervalItem = NSMenuItem(title: "Graph Interval", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for (label, secs) in [("1 min", 60.0), ("5 min", 300.0), ("15 min", 900.0), ("30 min", 1800.0)] {
            let mi = NSMenuItem(title: label, action: #selector(setGraphInterval(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = Int(secs)
            if abs(graphInterval - secs) < 1 { mi.state = .on }
            intervalMenu.addItem(mi)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        menu.addItem(NSMenuItem.separator())

        addMenuItem("Dashboard", action: #selector(openDashboard), key: "d")
        addMenuItem("Splash Screen", action: #selector(openSplash), key: "s")
        addMenuItem("APM Monitor", action: #selector(openAPM), key: "m")

        menu.addItem(NSMenuItem.separator())

        addMenuItem("Refresh", action: #selector(doRefresh), key: "r")
        menu.addItem(NSMenuItem(title: "Quit LFG Menubar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func addMenuItem(_ title: String, action: Selector, key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    func addSubItem(_ menu: NSMenu, _ title: String, action: Selector, key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    func makeStatItem(_ label: String, value: String, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let attrStr = NSMutableAttributedString()
        attrStr.append(NSAttributedString(string: "\(label): ",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        attrStr.append(NSAttributedString(string: value,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                         .foregroundColor: color]))
        item.attributedTitle = attrStr
        item.isEnabled = false
        return item
    }

    func updateTitle() {
        guard let button = statusItem.button else { return }
        let running = modules.first(where: { $0.value.status == "running" })
        if let r = running {
            button.title = "LFG \u{25B6} \(r.key.uppercased())"
        } else {
            button.title = "LFG \(diskFree)"
        }
    }

    // MARK: - Disk Stats Refresh

    func refreshStats() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let disk = Self.shell("df -h / | awk 'NR==2{print $4 \"|\" $5}'")
            let parts = disk.split(separator: "|")
            DispatchQueue.main.async {
                self?.diskFree = parts.count > 0 ? String(parts[0]) : "?"
                self?.diskUsed = parts.count > 1 ? String(parts[1]) : "?"
                if let pctStr = parts.count > 1 ? String(parts[1]).replacingOccurrences(of: "%", with: "") : nil {
                    self?.diskUsedPct = Double(pctStr) ?? 0
                }
                self?.updateTitle()
                self?.buildMenu()
            }
        }
    }

    // MARK: - Devdrive Config

    func refreshDevdriveConfig() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let devdriveDir = NSHomeDirectory() + "/tools/yj-devdrive"
            let script = """
            import sys; sys.path.insert(0, '\(devdriveDir)')
            from btau.core.config import load_config
            cfg = load_config()
            am = cfg.get('auto_move', {})
            mode = cfg.get('mount_mode', 'unknown')
            enabled = 'yes' if am.get('enabled') else 'no'
            print(f'{mode}|{enabled}')
            """
            let result = Self.shell("python3 -c \"\(script.replacingOccurrences(of: "\"", with: "\\\""))\"")
            let parts = result.split(separator: "|")
            DispatchQueue.main.async {
                self?.devdriveMountMode = parts.count > 0 ? String(parts[0]) : "unknown"
                self?.devdriveAutoMoveEnabled = parts.count > 1 && String(parts[1]) == "yes"
                self?.buildMenu()
            }
        }
    }

    // MARK: - Notifications

    func sendNotification(title: String, body: String) {
        let escaped_title = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escaped_body = body.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escaped_body)\" with title \"\(escaped_title)\" sound name \"Glass\""
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            try? task.run()
        }
    }

    // MARK: - Shell Helper

    static func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.arguments = ["-c", command]
        task.launchPath = "/bin/bash"
        do { try task.run(); task.waitUntilExit() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Module Launchers

    func launchLFG(_ args: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", "\(lfgPath) \(args)"]
            try? task.run()
        }
    }

    // WTFS actions
    @objc func openWTFS() { launchLFG("wtfs") }
    @objc func wtfsDeveloper() { launchLFG("wtfs ~/Developer") }
    @objc func wtfsHome() { launchLFG("wtfs ~") }
    @objc func wtfsRoot() { launchLFG("wtfs /") }

    // DTF actions
    @objc func openDTF() { launchLFG("dtf") }
    @objc func dtfScan() { launchLFG("dtf") }
    @objc func dtfForce() {
        sendNotification(title: "LFG DTF", body: "Cleaning caches...")
        launchLFG("dtf --force")
    }
    @objc func dtfForceDocker() {
        sendNotification(title: "LFG DTF", body: "Cleaning caches + Docker...")
        launchLFG("dtf --force --docker")
    }
    @objc func dtfForceSudo() {
        sendNotification(title: "LFG DTF", body: "Cleaning caches (sudo)...")
        launchLFG("dtf --force --sudo")
    }
    @objc func dtfNuclear() {
        sendNotification(title: "LFG DTF", body: "Full cleanup: caches + Docker + sudo...")
        launchLFG("dtf --force --docker --sudo")
    }

    // BTAU actions
    @objc func openBTAU() { launchLFG("btau --view") }
    @objc func btauDiscover() {
        sendNotification(title: "LFG BTAU", body: "Discovering volumes...")
        launchLFG("btau discover")
    }
    @objc func btauMount() { launchLFG("btau mount") }
    @objc func btauUnmount() { launchLFG("btau unmount") }

    // DEVDRIVE actions
    @objc func openDevdrive() { launchLFG("devdrive") }
    @objc func ddMount() {
        sendNotification(title: "LFG DEVDRIVE", body: "Mounting devdrive...")
        launchLFG("devdrive mount")
    }
    @objc func ddUnmount() {
        sendNotification(title: "LFG DEVDRIVE", body: "Unmounting devdrive...")
        launchLFG("devdrive unmount")
    }
    @objc func ddSync() {
        sendNotification(title: "LFG DEVDRIVE", body: "Syncing symlink forest...")
        launchLFG("devdrive sync")
    }
    @objc func ddVerify() {
        sendNotification(title: "LFG DEVDRIVE", body: "Verifying symlinks...")
        launchLFG("devdrive verify")
    }
    @objc func ddConfigShow() { launchLFG("devdrive config show") }
    @objc func ddAutoMoveDry() {
        sendNotification(title: "LFG DEVDRIVE", body: "Evaluating auto-move rules...")
        launchLFG("devdrive auto-move --dry-run")
    }
    @objc func ddAutoMoveForce() {
        sendNotification(title: "LFG DEVDRIVE", body: "Executing auto-move migrations...")
        launchLFG("devdrive auto-move --force")
    }

    // STFU actions
    @objc func openSTFU() { launchLFG("stfu") }
    @objc func stfuDryRun() {
        sendNotification(title: "LFG STFU", body: "Analyzing source trees (dry run)...")
        launchLFG("stfu --dry-run")
    }
    @objc func stfuExecute() {
        sendNotification(title: "LFG STFU", body: "Analyzing source trees (execute)...")
        launchLFG("stfu --execute")
    }
    @objc func stfuDeps() { launchLFG("stfu deps") }
    @objc func stfuFingerprint() { launchLFG("stfu fingerprint") }
    @objc func stfuDuplicates() { launchLFG("stfu duplicates") }
    @objc func stfuLibraries() { launchLFG("stfu libraries") }
    @objc func stfuEnvs() { launchLFG("stfu envs") }

    // AI actions
    @objc func aiConfigShow() { launchLFG("ai config show") }
    @objc func aiTestConnection() {
        sendNotification(title: "LFG AI", body: "Testing connection...")
        launchLFG("ai config show")
    }
    @objc func aiAnalyzeDeveloper() {
        sendNotification(title: "LFG AI", body: "Analyzing ~/Developer...")
        launchLFG("ai analyze ~/Developer")
    }

    // Settings actions
    @objc func settingsShow() { launchLFG("settings show") }
    @objc func settingsPaths() { launchLFG("settings paths") }
    @objc func settingsReset() {
        sendNotification(title: "LFG Settings", body: "Reset to defaults")
        launchLFG("settings reset")
    }

    // Other
    @objc func openDashboard() { launchLFG("dashboard") }
    @objc func openSplash() { launchLFG("") }
    @objc func openAPM() { NSWorkspace.shared.open(URL(string: "http://localhost:3031")!) }
    @objc func doRefresh() {
        refreshStats()
        refreshDevdriveConfig()
        recordDiskDataPoint()
        loadState()
        buildMenu()
    }

    @objc func setGraphInterval(_ sender: NSMenuItem) {
        graphInterval = TimeInterval(sender.tag)
        graphTimer?.invalidate()
        graphTimer = Timer.scheduledTimer(withTimeInterval: graphInterval, repeats: true) { [weak self] _ in
            self?.recordDiskDataPoint()
        }
        buildMenu()
        sendNotification(title: "LFG Menubar", body: "Graph interval: \(sender.title)")
    }
}

let delegate = LFGMenubar()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

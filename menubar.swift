import Cocoa

// =============================================================================
// LFG Menubar - Persistent status monitor with native notifications
// =============================================================================
// Watches ~/.config/lfg/state.json for module state changes.
// Shows live disk stats, module status, and sends notifications via osascript.
// =============================================================================

class LFGMenubar: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var refreshTimer: Timer?
    var fileWatchSource: DispatchSourceFileSystemObject?
    var previousState: [String: Any] = [:]

    let stateFile = NSHomeDirectory() + "/.config/lfg/state.json"
    let lfgPath = NSHomeDirectory() + "/tools/@yj/lfg/lfg"

    // Live stats
    var diskFree = "..."
    var diskUsed = "..."

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
    ]

    // --- Application Lifecycle ---

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No bundle needed for osascript-based notifications

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "LFG ..."
            button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        }

        loadState()
        buildMenu()
        startFileWatcher()

        // Periodic refresh every 60s as fallback
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshStats()
        }

        // Initial disk stats
        refreshStats()
        sendNotification(title: "LFG Menubar", body: "Monitoring active")
    }

    // --- State Management ---

    func loadState() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        diskFree = json["disk_free"] as? String ?? "?"
        diskUsed = json["disk_used"] as? String ?? "?"

        if let mods = json["modules"] as? [String: [String: Any]] {
            for (name, info) in mods {
                let status = info["status"] as? String ?? "idle"
                let updated = info["updated_at"] as? String ?? ""

                // Detect state transitions for notifications
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
        default:
            return info["status"] as? String ?? "?"
        }
    }

    // --- File Watcher ---

    func startFileWatcher() {
        // Ensure state file exists
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

    // --- Menu Construction ---

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
        menu.addItem(makeStatItem("Disk Used", value: diskUsed, color: .secondaryLabelColor))
        menu.addItem(NSMenuItem.separator())

        // Module status section
        for (name, mod) in modules.sorted(by: { $0.key < $1.key }) {
            let icon: String
            let color: NSColor
            switch mod.status {
            case "running":
                icon = "\u{25B6}"  // play
                color = .systemYellow
            case "completed":
                icon = "\u{2713}"  // check
                color = .systemGreen
            case "error":
                icon = "\u{2717}"  // x
                color = .systemRed
            default:
                icon = "\u{2022}"  // bullet
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

        // Module launchers
        addMenuItem("Open WTFS", action: #selector(openWTFS), key: "1")
        addMenuItem("Open DTF", action: #selector(openDTF), key: "2")
        addMenuItem("Open BTAU", action: #selector(openBTAU), key: "3")

        menu.addItem(NSMenuItem.separator())

        addMenuItem("Dashboard", action: #selector(openDashboard), key: "d")
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

        // Show running module indicator
        let running = modules.first(where: { $0.value.status == "running" })
        if let r = running {
            button.title = "LFG \u{25B6} \(r.key.uppercased())"
        } else {
            button.title = "LFG \(diskFree)"
        }
    }

    // --- Disk Stats Refresh ---

    func refreshStats() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let disk = Self.shell("df -h / | awk 'NR==2{print $4 \"|\" $5}'")
            let parts = disk.split(separator: "|")
            DispatchQueue.main.async {
                self?.diskFree = parts.count > 0 ? String(parts[0]) : "?"
                self?.diskUsed = parts.count > 1 ? String(parts[1]) : "?"
                self?.updateTitle()
                self?.buildMenu()
            }
        }
    }

    // --- Notifications ---

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

    // --- Shell Helper ---

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

    // --- Module Launchers ---

    func launchLFG(_ args: String) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", "\(lfgPath) \(args)"]
            try? task.run()
        }
    }

    @objc func openWTFS() { launchLFG("wtfs") }
    @objc func openDTF() { launchLFG("dtf") }
    @objc func openBTAU() { launchLFG("btau --view") }
    @objc func openDashboard() { launchLFG("dashboard") }
    @objc func openAPM() { NSWorkspace.shared.open(URL(string: "http://localhost:3031")!) }
    @objc func doRefresh() { refreshStats(); loadState(); buildMenu() }
}

let delegate = LFGMenubar()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

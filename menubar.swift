import Cocoa
import os.log
import UserNotifications

private let lfgMenuLog = OSLog(subsystem: "io.pegues.yj-tools.lfg.menubar", category: "menubar")

// =============================================================================
// LFG Helper v2 - Status monitor with actions, disk graph, notifications
// =============================================================================
// Watches ~/.config/lfg/state.json for module state changes.
// Provides actionable submenus for each module, disk usage sparkline,
// and sends notifications via osascript on state transitions.
// =============================================================================

// MARK: - Disk Graph View (custom NSView for menu item)

/// Renders disk usage bar graph as an NSImage for use in NSMenuItem
func renderDiskGraphImage(dataPoints: [(free: Double, used: Double, timestamp: String)]) -> NSImage {
    let maxPoints = 24
    let graphHeight: CGFloat = 48
    let barWidth: CGFloat = 8
    let barGap: CGFloat = 3
    let pad: CGFloat = 10
    let top: CGFloat = 20
    let imgW: CGFloat = 300
    let imgH: CGFloat = 84

    let image = NSImage(size: NSSize(width: imgW, height: imgH))
    image.lockFocus()

    let w = imgW - pad * 2
    let h = graphHeight

    // Title
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.6)
    ]
    ("DISK USAGE" as NSString).draw(at: NSPoint(x: pad, y: imgH - 14), withAttributes: titleAttrs)

    // Background
    NSColor(white: 0.12, alpha: 1).setFill()
    NSRect(x: pad, y: top, width: w, height: h).fill()

    guard !dataPoints.isEmpty else {
        let emptyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.3)
        ]
        ("No data yet" as NSString).draw(at: NSPoint(x: pad + 8, y: top + h/2 - 6), withAttributes: emptyAttrs)
        image.unlockFocus()
        return image
    }

    let count = min(dataPoints.count, maxPoints)
    let recent = Array(dataPoints.suffix(count))
    let totalW = barWidth + barGap
    let startX = pad + w - CGFloat(count) * totalW

    for (i, dp) in recent.enumerated() {
        let x = startX + CGFloat(i) * totalW
        let usedPct = dp.used / 100.0
        let barH = CGFloat(usedPct) * h

        let usedColor: NSColor
        if usedPct > 0.90 { usedColor = NSColor(red: 1, green: 0.3, blue: 0.42, alpha: 1) }
        else if usedPct > 0.80 { usedColor = NSColor(red: 1, green: 0.55, blue: 0.26, alpha: 1) }
        else if usedPct > 0.70 { usedColor = NSColor(red: 1, green: 0.82, blue: 0.4, alpha: 1) }
        else { usedColor = NSColor(red: 0.02, green: 0.84, blue: 0.63, alpha: 1) }

        usedColor.setFill()
        NSRect(x: x, y: top, width: barWidth, height: barH).fill()

        NSColor(red: 0.29, green: 0.62, blue: 1, alpha: 0.4).setFill()
        NSRect(x: x, y: top + barH, width: barWidth, height: h - barH).fill()
    }

    // Labels
    if let last = recent.last {
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6)
        ]
        let valStr = String(format: "%.0f%% used", last.used)
        (valStr as NSString).draw(at: NSPoint(x: pad + 2, y: 4), withAttributes: valAttrs)

        let freeStr = String(format: "Free: %.1f GB", last.free)
        (freeStr as NSString).draw(at: NSPoint(x: pad + w - 100, y: 4), withAttributes: valAttrs)
    }

    image.unlockFocus()
    return image
}

// MARK: - Helper Monitor Engine

struct HelperConfig {
    var enabled: Bool = true
    var checkIntervalMinutes: Int = 5
    var globalCooldownMinutes: Int = 30
    var quietHoursStart: String = "22:00"
    var quietHoursEnd: String = "07:00"
    struct MonitorConfig {
        var enabled: Bool = true
        var cooldownMinutes: Int = 60
        var warnPct: Int = 80
        var criticalPct: Int = 90
        var emergencyPct: Int = 95
        var warnDays: Int = 7
        var criticalDays: Int = 30
        var warnGB: Int = 10
    }
    var disk = MonitorConfig()
    var backupStaleness = MonitorConfig(enabled: true, cooldownMinutes: 1440, warnPct: 0, criticalPct: 0, emergencyPct: 0, warnDays: 7, criticalDays: 30, warnGB: 0)
    var cacheGrowth = MonitorConfig(enabled: true, cooldownMinutes: 360, warnPct: 0, criticalPct: 0, emergencyPct: 0, warnDays: 0, criticalDays: 0, warnGB: 10)
    var volumeHealth = MonitorConfig(enabled: true, cooldownMinutes: 120, warnPct: 0, criticalPct: 0, emergencyPct: 0, warnDays: 0, criticalDays: 0, warnGB: 0)
}

class HelperMonitor {
    let helperStateFile = NSHomeDirectory() + "/.config/lfg/helper_state.json"
    let lfgPath = NSHomeDirectory() + "/tools/@yj/lfg/lfg"
    var config = HelperConfig()
    var lastAlerts: [String: Date] = [:]
    var paused = false
    var activeConditions: [String] = []
    weak var delegate: LFGMenubar?

    func loadConfig() {
        let raw = LFGMenubar.shell(NSHomeDirectory() + "/tools/@yj/lfg/lfg settings show --json")
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let helper = json["helper"] as? [String: Any] else { return }

        config.enabled = helper["enabled"] as? Bool ?? true
        config.checkIntervalMinutes = helper["check_interval_minutes"] as? Int ?? 5
        config.globalCooldownMinutes = helper["global_cooldown_minutes"] as? Int ?? 30
        config.quietHoursStart = helper["quiet_hours_start"] as? String ?? "22:00"
        config.quietHoursEnd = helper["quiet_hours_end"] as? String ?? "07:00"

        if let monitors = helper["monitors"] as? [String: Any] {
            if let d = monitors["disk"] as? [String: Any] {
                config.disk.enabled = d["enabled"] as? Bool ?? true
                config.disk.warnPct = d["warn_pct"] as? Int ?? 80
                config.disk.criticalPct = d["critical_pct"] as? Int ?? 90
                config.disk.emergencyPct = d["emergency_pct"] as? Int ?? 95
                config.disk.cooldownMinutes = d["cooldown_minutes"] as? Int ?? 60
            }
            if let b = monitors["backup_staleness"] as? [String: Any] {
                config.backupStaleness.enabled = b["enabled"] as? Bool ?? true
                config.backupStaleness.warnDays = b["warn_days"] as? Int ?? 7
                config.backupStaleness.criticalDays = b["critical_days"] as? Int ?? 30
                config.backupStaleness.cooldownMinutes = b["cooldown_minutes"] as? Int ?? 1440
            }
            if let c = monitors["cache_growth"] as? [String: Any] {
                config.cacheGrowth.enabled = c["enabled"] as? Bool ?? true
                config.cacheGrowth.warnGB = c["warn_gb"] as? Int ?? 10
                config.cacheGrowth.cooldownMinutes = c["cooldown_minutes"] as? Int ?? 360
            }
            if let v = monitors["volume_health"] as? [String: Any] {
                config.volumeHealth.enabled = v["enabled"] as? Bool ?? true
                config.volumeHealth.cooldownMinutes = v["cooldown_minutes"] as? Int ?? 120
            }
        }
    }

    func loadState() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: helperStateFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        let formatter = ISO8601DateFormatter()
        for (key, val) in json {
            if let date = formatter.date(from: val) {
                lastAlerts[key] = date
            }
        }
    }

    func saveState() {
        let formatter = ISO8601DateFormatter()
        let dict = lastAlerts.mapValues { formatter.string(from: $0) }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) else { return }
        try? data.write(to: URL(fileURLWithPath: helperStateFile))
    }

    func isQuietHours() -> Bool {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let minute = cal.component(.minute, from: now)
        let nowMinutes = hour * 60 + minute

        let startParts = config.quietHoursStart.split(separator: ":")
        let endParts = config.quietHoursEnd.split(separator: ":")
        guard startParts.count == 2, endParts.count == 2 else { return false }
        let startMin = (Int(startParts[0]) ?? 22) * 60 + (Int(startParts[1]) ?? 0)
        let endMin = (Int(endParts[0]) ?? 7) * 60 + (Int(endParts[1]) ?? 0)

        if startMin > endMin {
            // Wraps midnight: 22:00-07:00
            return nowMinutes >= startMin || nowMinutes < endMin
        } else {
            return nowMinutes >= startMin && nowMinutes < endMin
        }
    }

    func shouldAlert(check: String, cooldownMinutes: Int) -> Bool {
        guard let last = lastAlerts[check] else { return true }
        return Date().timeIntervalSince(last) >= Double(cooldownMinutes * 60)
    }

    func recordAlert(check: String) {
        lastAlerts[check] = Date()
        saveState()
    }

    // MARK: - Run All Checks

    func runChecks() {
        guard config.enabled, !paused, !isQuietHours() else { return }
        guard let delegate = delegate else { return }
        activeConditions = []

        checkDisk(delegate: delegate)
        checkBackupStaleness(delegate: delegate)
        checkCacheGrowth(delegate: delegate)
        checkVolumeHealth(delegate: delegate)
    }

    // MARK: - Disk Usage Monitor (WTFS blue)

    func checkDisk(delegate: LFGMenubar) {
        guard config.disk.enabled else { return }
        let pct = Int(delegate.diskUsedPct)

        if pct >= config.disk.emergencyPct {
            activeConditions.append("Disk: \(pct)% EMERGENCY")
            if shouldAlert(check: "disk_emergency", cooldownMinutes: config.disk.cooldownMinutes) {
                delegate.sendNotification(title: "LFG WTFS", body: "EMERGENCY: Disk \(pct)% full! Run: lfg dtf --force")
                recordAlert(check: "disk_emergency")
            }
        } else if pct >= config.disk.criticalPct {
            activeConditions.append("Disk: \(pct)% critical")
            if shouldAlert(check: "disk_critical", cooldownMinutes: config.disk.cooldownMinutes) {
                delegate.sendNotification(title: "LFG WTFS", body: "Disk usage critical: \(pct)%. Consider running cache cleanup.")
                recordAlert(check: "disk_critical")
            }
        } else if pct >= config.disk.warnPct {
            activeConditions.append("Disk: \(pct)% warning")
            if shouldAlert(check: "disk_warn", cooldownMinutes: config.disk.cooldownMinutes) {
                delegate.sendNotification(title: "LFG WTFS", body: "Disk usage at \(pct)%. Monitor or consider cleanup.")
                recordAlert(check: "disk_warn")
            }
        }
    }

    // MARK: - Backup Staleness Monitor (BTAU green)

    func checkBackupStaleness(delegate: LFGMenubar) {
        guard config.backupStaleness.enabled else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/.config/lfg/state.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lastClean = json["last_clean"] as? String else { return }

        let formatter = ISO8601DateFormatter()
        guard let lastDate = formatter.date(from: lastClean) else { return }
        let daysSince = Int(Date().timeIntervalSince(lastDate) / 86400)

        if daysSince >= config.backupStaleness.criticalDays {
            activeConditions.append("Backup: \(daysSince)d stale")
            if shouldAlert(check: "backup_critical", cooldownMinutes: config.backupStaleness.cooldownMinutes) {
                delegate.sendNotification(title: "LFG BTAU", body: "Last cleanup was \(daysSince) days ago. Run: lfg dtf")
                recordAlert(check: "backup_critical")
            }
        } else if daysSince >= config.backupStaleness.warnDays {
            activeConditions.append("Backup: \(daysSince)d since cleanup")
            if shouldAlert(check: "backup_warn", cooldownMinutes: config.backupStaleness.cooldownMinutes) {
                delegate.sendNotification(title: "LFG BTAU", body: "No cleanup in \(daysSince) days. Consider running: lfg dtf")
                recordAlert(check: "backup_warn")
            }
        }
    }

    // MARK: - Cache Growth Monitor (DTF orange)

    func checkCacheGrowth(delegate: LFGMenubar) {
        guard config.cacheGrowth.enabled else { return }
        // Read from state.json if DTF has recent scan data
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/.config/lfg/state.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mods = json["modules"] as? [String: [String: Any]],
              let dtf = mods["dtf"],
              let reclaimable = dtf["reclaimable"] as? String else { return }

        // Parse reclaimable like "12.3 GB"
        let parts = reclaimable.split(separator: " ")
        guard let gb = Double(parts.first ?? "0") else { return }

        if gb >= Double(config.cacheGrowth.warnGB) {
            activeConditions.append("Cache: \(reclaimable) reclaimable")
            if shouldAlert(check: "cache_growth", cooldownMinutes: config.cacheGrowth.cooldownMinutes) {
                delegate.sendNotification(title: "LFG DTF", body: "\(reclaimable) reclaimable. Run: lfg dtf --force")
                recordAlert(check: "cache_growth")
            }
        }
    }

    // MARK: - Volume Health Monitor (DEVDRIVE purple)

    func checkVolumeHealth(delegate: LFGMenubar) {
        guard config.volumeHealth.enabled else { return }
        for profile in delegate.volumeProfiles {
            if !profile.mounted {
                activeConditions.append("\(profile.name): unmounted")
                if shouldAlert(check: "volume_\(profile.name)", cooldownMinutes: config.volumeHealth.cooldownMinutes) {
                    delegate.sendNotification(title: "LFG DEVDRIVE", body: "\(profile.name) (\(profile.purpose)) is not mounted.")
                    recordAlert(check: "volume_\(profile.name)")
                }
            }
        }
    }
}

// MARK: - Main Application

class LFGMenubar: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var refreshTimer: Timer?
    var graphTimer: Timer?
    var helperTimer: Timer?
    var fileWatchSource: DispatchSourceFileSystemObject?
    var promptsWatchSource: DispatchSourceFileSystemObject?
    var pendingPromptCount: Int = 0
    var previousState: [String: Any] = [:]
    let helperMonitor = HelperMonitor()

    let stateFile = NSHomeDirectory() + "/.config/lfg/state.json"
    let historyFile = NSHomeDirectory() + "/.config/lfg/disk_history.json"
    let lfgPath = NSHomeDirectory() + "/tools/@yj/lfg/lfg"

    // Live stats
    var diskFree = "..."
    var diskUsed = "..."
    var diskUsedPct: Double = 0

    // Disk history for graph
    var diskHistory: [(free: Double, used: Double, timestamp: String)] = []

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

    // Volume profiles from settings.yaml
    struct VolumeProfile {
        let name: String
        let purpose: String
        let color: String
        let mounted: Bool
        let freeGB: Double
    }
    var volumeProfiles: [VolumeProfile] = []

    // MARK: - Application Lifecycle

    /// Draw LFG wordmark as menubar icon -- bold "LFG" text rendered as template image
    func makeBrandmarkIcon() -> NSImage {
        let text = "LFG" as NSString
        let font = NSFont.systemFont(ofSize: 12, weight: .black)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black  // template mode inverts automatically
        ]
        let textSize = text.size(withAttributes: attrs)
        let imgSize = NSSize(width: ceil(textSize.width) + 2, height: 18)
        let img = NSImage(size: imgSize, flipped: false) { rect in
            let y = (rect.height - textSize.height) / 2.0
            text.draw(at: NSPoint(x: 1, y: y), withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        return img
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = makeBrandmarkIcon()
            button.imagePosition = .imageLeading
            button.title = ""
            button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            button.setAccessibilityLabel("LFG Disk Management Menu")
            button.setAccessibilityHelp("Click to open LFG module and disk management menu")
        }

        // US-007: Register for viewer IPC notifications
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleViewerNotification(_:)),
            name: NSNotification.Name("com.lfg.viewer.settingsChanged"), object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleViewerNotification(_:)),
            name: NSNotification.Name("com.lfg.viewer.actionCompleted"), object: nil
        )

        loadDiskHistory()
        loadState()
        buildMenu()
        startFileWatcher()
        watchPromptsDir()

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
        refreshVolumeProfiles()
        recordDiskDataPoint()

        // Initialize Helper Monitor
        helperMonitor.delegate = self
        helperMonitor.loadConfig()
        helperMonitor.loadState()
        let helperInterval = TimeInterval(helperMonitor.config.checkIntervalMinutes * 60)
        helperTimer = Timer.scheduledTimer(withTimeInterval: helperInterval, repeats: true) { [weak self] _ in
            self?.helperMonitor.runChecks()
        }
        // Run first check after a brief delay (let stats populate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.helperMonitor.runChecks()
        }

        os_log("Helper launched, state: %{public}@", log: lfgMenuLog, type: .info, stateFile)
        sendNotification(title: "LFG Helper", body: "Monitoring active")
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
            // APFS-aware: use capacity% for used, calculate free from total
            let raw = Self.shell("df / | awk 'NR==2{t=$2*512/1e9;p=$5+0;a=$4*512/1e9;printf \"%.1f|%.1f|%d\",t,a,p}'")
            let parts = raw.split(separator: "|")
            guard parts.count >= 3 else { return }
            let usedPct = Double(String(parts[2])) ?? 0
            let freeGB = Double(String(parts[1])) ?? 0

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

    // MARK: - Prompts Watcher (in-use detection notifications)

    func watchPromptsDir() {
        let promptsDir = NSHomeDirectory() + "/.config/lfg/prompts"
        let fm = FileManager.default
        if !fm.fileExists(atPath: promptsDir) {
            try? fm.createDirectory(atPath: promptsDir, withIntermediateDirectories: true, attributes: nil)
        }

        let fd = open(promptsDir, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.processPrompts()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        promptsWatchSource = source
    }

    func processPrompts() {
        let promptsDir = NSHomeDirectory() + "/.config/lfg/prompts"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: promptsDir) else { return }

        var pendingCount = 0
        for file in files where file.hasSuffix(".json") {
            let path = promptsDir + "/" + file
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String else { continue }

            if status == "pending" {
                pendingCount += 1
                let project = json["project"] as? String ?? "Unknown"
                let sizeGB = json["size_gb"] as? Double ?? 0
                let source = json["source"] as? String ?? ""
                let dest = json["dest"] as? String ?? ""

                // Show alert
                DispatchQueue.main.async { [weak self] in
                    let alert = NSAlert()
                    alert.messageText = "Move \(project)?"
                    alert.informativeText = "This project (\(String(format: "%.1f", sizeGB)) GB) is currently in use.\n\nFrom: \(source)\nTo: \(dest)\n\nMove anyway?"
                    alert.addButton(withTitle: "Move")
                    alert.addButton(withTitle: "Skip")
                    alert.addButton(withTitle: "Defer")
                    alert.alertStyle = .informational

                    let response = alert.runModal()
                    var responseStr = "skip"
                    switch response {
                    case .alertFirstButtonReturn: responseStr = "yes"
                    case .alertSecondButtonReturn: responseStr = "skip"
                    default: responseStr = "defer"
                    }

                    // Write response back
                    var mutableJson = json
                    mutableJson["response"] = responseStr
                    mutableJson["status"] = "responded"
                    if let updatedData = try? JSONSerialization.data(withJSONObject: mutableJson, options: .prettyPrinted) {
                        try? updatedData.write(to: URL(fileURLWithPath: path))
                    }
                    self?.pendingPromptCount = max(0, (self?.pendingPromptCount ?? 1) - 1)
                    NSApp.dockTile.badgeLabel = (self?.pendingPromptCount ?? 0) > 0 ? "\(self?.pendingPromptCount ?? 0)" : nil
                }
            }
        }

        pendingPromptCount = pendingCount
        NSApp.dockTile.badgeLabel = pendingCount > 0 ? "\(pendingCount)" : nil
        if pendingCount > 0 {
            sendNotification(title: "LFG Auto-Move", body: "\(pendingCount) project(s) need your decision")
        }
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
        header.setAccessibilityLabel("LFG - Local File Guardian status menu")
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // Disk stats
        menu.addItem(makeStatItem("Disk Free", value: diskFree, color: .systemBlue))
        menu.addItem(makeStatItem("Disk Used", value: diskUsed, color: diskUsedPct > 90 ? .systemRed : .secondaryLabelColor))
        menu.addItem(NSMenuItem.separator())

        // Disk graph - rendered as NSImage for reliable display in NSMenu
        let graphItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        graphItem.image = renderDiskGraphImage(dataPoints: diskHistory)
        graphItem.isEnabled = false
        menu.addItem(graphItem)
        menu.addItem(NSMenuItem.separator())

        // Helper Monitor status
        let helperHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let helperStatus = helperMonitor.paused ? "PAUSED" : (helperMonitor.activeConditions.isEmpty ? "OK" : "\(helperMonitor.activeConditions.count) alert(s)")
        let helperColor: NSColor = helperMonitor.paused ? .secondaryLabelColor : (helperMonitor.activeConditions.isEmpty ? .systemGreen : .systemOrange)
        let helperAttr = NSMutableAttributedString()
        helperAttr.append(NSAttributedString(string: "Helper ",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                         .foregroundColor: NSColor.labelColor]))
        helperAttr.append(NSAttributedString(string: helperStatus,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                         .foregroundColor: helperColor]))
        helperHeader.attributedTitle = helperAttr
        helperHeader.isEnabled = false
        menu.addItem(helperHeader)

        // Show active conditions
        for condition in helperMonitor.activeConditions {
            let condItem = NSMenuItem(title: "  \(condition)", action: nil, keyEquivalent: "")
            condItem.attributedTitle = NSAttributedString(string: "  \(condition)",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                             .foregroundColor: NSColor.systemOrange])
            condItem.isEnabled = false
            menu.addItem(condItem)
        }

        // Pause/Resume toggle
        let toggleTitle = helperMonitor.paused ? "Resume Helper" : "Pause Helper"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleHelper), keyEquivalent: "h")
        toggleItem.target = self
        menu.addItem(toggleItem)
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
        let btauItem = NSMenuItem(title: "BTAU - Back That App Up", action: nil, keyEquivalent: "")
        let btauMenu = NSMenu()
        addSubItem(btauMenu, "View Status", action: #selector(openBTAU), key: "3")
        btauMenu.addItem(NSMenuItem.separator())
        addSubItem(btauMenu, "Migrate Project...", action: #selector(btauMigrate), key: "")
        addSubItem(btauMenu, "Auto-Move (Dry Run)", action: #selector(btauAutoMoveDry), key: "")
        addSubItem(btauMenu, "Auto-Move (Execute)", action: #selector(btauAutoMoveExec), key: "")
        btauMenu.addItem(NSMenuItem.separator())
        addSubItem(btauMenu, "Backup Now", action: #selector(btauBackup), key: "")
        addSubItem(btauMenu, "Restore...", action: #selector(btauRestore), key: "")
        addSubItem(btauMenu, "Rebuild Forest", action: #selector(btauRebuild), key: "")
        btauMenu.addItem(NSMenuItem.separator())
        addSubItem(btauMenu, "New Project", action: #selector(btauNew), key: "")
        addSubItem(btauMenu, "Discover Volumes", action: #selector(btauDiscover), key: "")
        addSubItem(btauMenu, "Configuration", action: #selector(btauConfig), key: "")
        btauItem.submenu = btauMenu
        menu.addItem(btauItem)

        // --- DEVDRIVE Actions Submenu (per-profile) ---
        let mountedCount = volumeProfiles.filter { $0.mounted }.count
        let totalCount = volumeProfiles.count
        let ddTitle = totalCount > 0 ? "DEVDRIVE [\(mountedCount)/\(totalCount) mounted]" : "DEVDRIVE"
        let ddItem = NSMenuItem(title: ddTitle, action: nil, keyEquivalent: "")
        let ddMenu = NSMenu()
        addSubItem(ddMenu, "View Status", action: #selector(openDevdrive), key: "4")
        ddMenu.addItem(NSMenuItem.separator())

        // Per-profile sections
        if volumeProfiles.isEmpty {
            let noProfiles = NSMenuItem(title: "No volume profiles configured", action: nil, keyEquivalent: "")
            noProfiles.isEnabled = false
            ddMenu.addItem(noProfiles)
        } else {
            for prof in volumeProfiles {
                let dot = prof.mounted ? "\u{25CF}" : "\u{25CB}"  // filled/empty circle
                let status = prof.mounted ? "Mounted (\(String(format: "%.1f", prof.freeGB)) GB free)" : "Not Mounted"
                let header = NSMenuItem(title: "\(dot) \(prof.name) - \(prof.purpose)", action: nil, keyEquivalent: "")
                header.isEnabled = false
                ddMenu.addItem(header)

                let statusItem = NSMenuItem(title: "    \(status)", action: nil, keyEquivalent: "")
                statusItem.isEnabled = false
                ddMenu.addItem(statusItem)

                if prof.mounted {
                    let unmountItem = NSMenuItem(title: "    Unmount", action: #selector(ddProfileAction(_:)), keyEquivalent: "")
                    unmountItem.target = self
                    unmountItem.representedObject = "devdrive unmount --profile=\(prof.name)" as NSString
                    ddMenu.addItem(unmountItem)

                    let syncItem = NSMenuItem(title: "    Sync Forest", action: #selector(ddProfileAction(_:)), keyEquivalent: "")
                    syncItem.target = self
                    syncItem.representedObject = "devdrive sync --profile=\(prof.name)" as NSString
                    ddMenu.addItem(syncItem)

                    let verifyItem = NSMenuItem(title: "    Verify Links", action: #selector(ddProfileAction(_:)), keyEquivalent: "")
                    verifyItem.target = self
                    verifyItem.representedObject = "devdrive verify --profile=\(prof.name)" as NSString
                    ddMenu.addItem(verifyItem)
                } else {
                    let mountItem = NSMenuItem(title: "    Mount", action: #selector(ddProfileAction(_:)), keyEquivalent: "")
                    mountItem.target = self
                    mountItem.representedObject = "devdrive mount --profile=\(prof.name)" as NSString
                    ddMenu.addItem(mountItem)
                }
                ddMenu.addItem(NSMenuItem.separator())
            }
        }

        addSubItem(ddMenu, "Auto-Move (Dry Run)", action: #selector(ddAutoMoveDry), key: "")
        addSubItem(ddMenu, "Auto-Move (Execute)", action: #selector(ddAutoMoveForce), key: "")
        ddMenu.addItem(NSMenuItem.separator())
        addSubItem(ddMenu, "Show Config", action: #selector(ddConfigShow), key: "")
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
        addSubItem(aiMenu, "Open Chat", action: #selector(openChat), key: "6")
        addSubItem(aiMenu, "Quick Ask...", action: #selector(quickAsk), key: "")
        aiMenu.addItem(NSMenuItem.separator())
        addSubItem(aiMenu, "Show Config", action: #selector(aiConfigShow), key: "")
        addSubItem(aiMenu, "Test Connection", action: #selector(aiTestConnection), key: "")
        aiMenu.addItem(NSMenuItem.separator())
        addSubItem(aiMenu, "Analyze ~/Developer", action: #selector(aiAnalyzeDeveloper), key: "")
        addSubItem(aiMenu, "Compare Projects", action: #selector(aiCompare), key: "")
        addSubItem(aiMenu, "Suggest Optimizations", action: #selector(aiSuggest), key: "")
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
        menu.addItem(NSMenuItem(title: "Quit LFG Helper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

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
            button.title = " \u{25B6} \(r.key.uppercased())"
        } else {
            button.title = " \(diskFree)"
        }
    }

    // MARK: - Disk Stats Refresh

    func refreshStats() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // APFS-aware: calculate used from total * capacity%, output in GB
            let disk = Self.shell("df / | awk 'NR==2{t=int($2*512/1e9+.5);p=$5+0;u=int(t*p/100+.5);a=$4*512/1e9;printf \"%d|%d|%.1f|%d\",t,u,a,p}'")
            let parts = disk.split(separator: "|")
            DispatchQueue.main.async {
                let totalGB = parts.count > 0 ? String(parts[0]) : "?"
                let usedGB = parts.count > 1 ? String(parts[1]) : "?"
                let availGB = parts.count > 2 ? String(parts[2]) : "?"
                let pct = parts.count > 3 ? Double(String(parts[3])) ?? 0 : 0
                self?.diskFree = "\(availGB) GB"
                self?.diskUsed = "\(usedGB) of \(totalGB) GB (\(Int(pct))%)"
                self?.diskUsedPct = pct
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

    // MARK: - Volume Profiles

    func refreshVolumeProfiles() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lfgDir = NSHomeDirectory() + "/tools/@yj/lfg"
            let result = Self.shell("\(lfgDir)/lfg settings show --json 2>/dev/null")
            var profiles: [VolumeProfile] = []
            if let data = result.data(using: .utf8) {
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let profs = json["volume_profiles"] as? [[String: Any]] {
                        for p in profs {
                            let name = p["name"] as? String ?? ""
                            let purpose = p["purpose"] as? String ?? ""
                            let color = p["color"] as? String ?? "#c084fc"
                            let mounted = FileManager.default.fileExists(atPath: "/Volumes/\(name)")
                            var freeGB: Double = 0
                            if mounted {
                                let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/Volumes/\(name)")
                                if let freeBytes = attrs?[.systemFreeSize] as? Int64 {
                                    freeGB = Double(freeBytes) / (1024 * 1024 * 1024)
                                }
                            }
                            profiles.append(VolumeProfile(name: name, purpose: purpose, color: color, mounted: mounted, freeGB: freeGB))
                        }
                    }
                } catch {}
            }
            DispatchQueue.main.async {
                self?.volumeProfiles = profiles
                self?.buildMenu()
            }
        }
    }

    // MARK: - Notifications (UNUserNotificationCenter)

    func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
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
    @objc func btauMigrate() {
        sendNotification(title: "LFG BTAU", body: "Opening migrate wizard...")
        launchLFG("btau migrate")
    }
    @objc func btauAutoMoveDry() {
        sendNotification(title: "LFG BTAU", body: "Auto-move dry run...")
        launchLFG("btau auto-move")
    }
    @objc func btauAutoMoveExec() {
        sendNotification(title: "LFG BTAU", body: "Executing auto-move...")
        launchLFG("btau auto-move --execute")
    }
    @objc func btauBackup() {
        sendNotification(title: "LFG BTAU", body: "Starting backup...")
        launchLFG("btau backup")
    }
    @objc func btauRestore() {
        sendNotification(title: "LFG BTAU", body: "Opening restore...")
        launchLFG("btau restore")
    }
    @objc func btauRebuild() {
        sendNotification(title: "LFG BTAU", body: "Rebuilding symlink forest...")
        launchLFG("btau rebuild")
    }
    @objc func btauNew() {
        sendNotification(title: "LFG BTAU", body: "Creating new project...")
        launchLFG("btau new")
    }
    @objc func btauDiscover() {
        sendNotification(title: "LFG BTAU", body: "Discovering volumes...")
        launchLFG("btau discover")
    }
    @objc func btauConfig() { launchLFG("btau config") }

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
    @objc func ddProfileAction(_ sender: NSMenuItem) {
        guard let cmd = sender.representedObject as? NSString else { return }
        sendNotification(title: "LFG DEVDRIVE", body: "Running: \(cmd)")
        launchLFG(cmd as String)
    }
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

    // Chat actions
    @objc func openChat() { launchLFG("chat") }
    @objc func quickAsk() {
        let alert = NSAlert()
        alert.messageText = "Quick Ask"
        alert.informativeText = "Enter your question for LFG:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Ask")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "e.g. What's using the most space?"
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let question = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty {
                sendNotification(title: "LFG Chat", body: "Asking...")
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let escaped = question.replacingOccurrences(of: "'", with: "'\\''")
                    let result = Self.shell("\(lfgPath) chat send '\(escaped)'")
                    DispatchQueue.main.async {
                        self.sendNotification(title: "LFG Chat", body: String(result.prefix(200)))
                    }
                }
            }
        }
    }

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

    @objc func aiCompare() {
        sendNotification(title: "LFG AI", body: "Comparing projects...")
        launchLFG("ai compare")
    }
    @objc func aiSuggest() {
        sendNotification(title: "LFG AI", body: "Generating suggestions...")
        launchLFG("ai suggest")
    }

    // US-007: IPC handler for viewer notifications
    @objc func handleViewerNotification(_ notification: Notification) {
        DispatchQueue.main.async { [self] in
            refreshStats()
            loadState()
            buildMenu()
        }
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
        refreshVolumeProfiles()
        recordDiskDataPoint()
        helperMonitor.runChecks()
        loadState()
        buildMenu()
    }

    @objc func toggleHelper() {
        helperMonitor.paused = !helperMonitor.paused
        let status = helperMonitor.paused ? "paused" : "resumed"
        sendNotification(title: "LFG Helper", body: "Monitoring \(status)")
        buildMenu()
    }

    @objc func setGraphInterval(_ sender: NSMenuItem) {
        graphInterval = TimeInterval(sender.tag)
        graphTimer?.invalidate()
        graphTimer = Timer.scheduledTimer(withTimeInterval: graphInterval, repeats: true) { [weak self] _ in
            self?.recordDiskDataPoint()
        }
        // US-005: Persist graph interval to settings.yaml
        DispatchQueue.global().async { [self] in
            let task = Process()
            task.launchPath = "/bin/bash"
            task.arguments = ["-c", "\(lfgPath) settings set graph_interval \(sender.tag)"]
            try? task.run()
        }
        buildMenu()
        sendNotification(title: "LFG Helper", body: "Graph interval: \(sender.title)")
    }
}

let delegate = LFGMenubar()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

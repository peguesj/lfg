import Cocoa
import Darwin

// MARK: - Constants

private let kTotalBytes: Double = 12.0 * 1_073_741_824
private let kVolumePath  = "/Volumes/SURFACE"
private let kSurfaceUUID = "3CB61154-8C14-3116-8522-6A7E10D63C17"
private let kAPMEndpoint = "http://localhost:3032/api/notify"
private let kCopyManager = "/Users/jeremiah/tools/@yj/lfg/scripts/usb-copy-manager.sh"
private let kPollInterval: TimeInterval = 2.0

// MARK: - Helpers

private func volumeUsedBytes(at path: String) -> Double? {
    var st = statvfs()
    guard statvfs(path, &st) == 0 else { return nil }
    let blockSize = Double(st.f_frsize > 0 ? st.f_frsize : st.f_bsize)
    let total     = Double(st.f_blocks) * blockSize
    let avail     = Double(st.f_bavail) * blockSize
    return total - avail
}

private func isDittoRunning() -> Bool {
    let task = Process()
    task.launchPath = "/usr/bin/pgrep"
    task.arguments  = ["-q", "ditto"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError  = FileHandle.nullDevice
    try? task.run(); task.waitUntilExit()
    return task.terminationStatus == 0
}

private func findVolumeByUUID(_ uuid: String) -> String? {
    let task = Process()
    task.launchPath = "/usr/sbin/diskutil"
    task.arguments  = ["info", "UUID:\(uuid)"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError  = FileHandle.nullDevice
    try? task.run(); task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    for line in out.components(separatedBy: "\n") {
        if line.contains("Mount Point") {
            let mp = line.components(separatedBy: ":").dropFirst()
                .joined(separator: ":").trimmingCharacters(in: .whitespaces)
            if !mp.isEmpty && mp != "(null)" { return mp }
        }
    }
    return nil
}

private func runCopyManager(_ args: [String], wait: Bool = false) {
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments  = [kCopyManager] + args
    task.standardOutput = FileHandle.nullDevice
    task.standardError  = FileHandle.nullDevice
    try? task.run()
    if wait { task.waitUntilExit() }
}

private func bootFilesPresent(at base: String) -> (bootx64: Bool, bootmgr: Bool, sources: Bool, swmCount: Int) {
    let fm = FileManager.default
    let bootx64  = fm.fileExists(atPath: "\(base)/EFI/Boot/bootx64.efi")
    let bootmgr  = fm.fileExists(atPath: "\(base)/bootmgr.efi")
    let sources  = fm.fileExists(atPath: "\(base)/sources")
    var swmCount = 0
    if let items = try? fm.contentsOfDirectory(atPath: "\(base)/sources") {
        swmCount = items.filter { $0.hasPrefix("install") && $0.hasSuffix(".swm") }.count
    }
    return (bootx64, bootmgr, sources, swmCount)
}

private func postAPM(event: String, data: [String: Any]) {
    guard let url = URL(string: kAPMEndpoint) else { return }
    var body: [String: Any] = ["source": "lfg-usb-monitor", "event": event, "data": data,
                                "project": "lfg", "timestamp": isoNow()]
    body["data"] = data
    guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.httpBody   = payload
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 3
    URLSession.shared.dataTask(with: req).resume()
}

private func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func ejectDisk() {
    let task = Process()
    task.launchPath = "/usr/sbin/diskutil"
    task.arguments  = ["eject", "/dev/disk8"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError  = FileHandle.nullDevice
    try? task.run()
}

// MARK: - Progress Model

private struct Sample { let bytes: Double; let time: Date }

private class ProgressModel {
    var samples: [Sample] = []
    var lastMilestone: Int = -1
    var finished = false
    var latest: Sample? { samples.last }

    func addSample(_ bytes: Double) {
        samples.append(Sample(bytes: bytes, time: Date()))
        if samples.count > 20 { samples.removeFirst() }
    }
    var speedBps: Double {
        guard samples.count >= 2 else { return 0 }
        let old = samples[max(0, samples.count - 8)]
        let now = samples.last!
        let dt  = now.time.timeIntervalSince(old.time)
        guard dt > 0 else { return 0 }
        return (now.bytes - old.bytes) / dt
    }
    var pct: Double {
        guard let b = latest?.bytes else { return 0 }
        return min((b / kTotalBytes) * 100.0, 99.9)
    }
    var etaSeconds: Double? {
        let spd = speedBps
        guard spd > 1_000, let b = latest?.bytes else { return nil }
        return max(kTotalBytes - b, 0) / spd
    }
    var phase: String {
        let p = pct
        switch p {
        case ..<2:  return "initialising"
        case ..<5:  return "boot files"
        case ..<17: return "boot.wim"
        case ..<91: return "install segments (\(Int(p))%)"
        case ..<99: return "final files"
        default:    return "verifying"
        }
    }
}

// MARK: - Formatters

private func makeFilledBar(pct: Double, width: Int = 14) -> String {
    let filled = Int((pct / 100.0) * Double(width))
    return String(repeating: "▓", count: filled) + String(repeating: "░", count: max(0, width - filled))
}
private func formatBytes(_ b: Double) -> String {
    if b >= 1_073_741_824 { return String(format: "%.1f GB", b / 1_073_741_824) }
    if b >= 1_048_576     { return String(format: "%.0f MB", b / 1_048_576) }
    return String(format: "%.0f KB", b / 1_024)
}
private func formatETA(_ secs: Double) -> String {
    if secs < 60   { return "\(Int(secs))s" }
    if secs < 3600 { return "\(Int(secs / 60))m \(Int(secs.truncatingRemainder(dividingBy: 60)))s" }
    return "\(Int(secs / 3600))h"
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let model = ProgressModel()
    private var quitOnDone = true

    // Pause / resume state
    private var copyPaused        = false
    private var waitingForReconnect = false

    // Menu items — progress
    private var miTitle   = NSMenuItem()
    private var miBar     = NSMenuItem()
    private var miDetail  = NSMenuItem()
    private var miSpeed   = NSMenuItem()
    private var miETA     = NSMenuItem()
    private var miPhase   = NSMenuItem()
    private var miVolume  = NSMenuItem()

    // Menu items — controls
    private var miPauseResume = NSMenuItem()
    private var miDriveStatus = NSMenuItem()

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.title = "USB …"

        buildMenu()

        postAPM(event: "usb_monitor_launched", data: [
            "timestamp": isoNow(), "total_gb": 12,
            "volume": kVolumePath, "surface_uuid": kSurfaceUUID
        ])

        timer = Timer.scheduledTimer(withTimeInterval: kPollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    // MARK: - Tick

    private func tick() {
        // ── Reconnect-waiting mode ──────────────────────────────────────
        if waitingForReconnect {
            if let mount = findVolumeByUUID(kSurfaceUUID) {
                waitingForReconnect = false
                copyPaused = false
                statusItem.button?.title = "USB ↺ resuming…"
                miDriveStatus.title = "  Drive reconnected: \(mount)"
                miPauseResume.title = "Pause copy"
                miPauseResume.isEnabled = true
                postAPM(event: "usb_drive_reconnected", data: ["mount": mount, "timestamp": isoNow()])
                // Launch smart-copy resume in background
                runCopyManager(["resume"])
                // Restart monitoring
                model.samples.removeAll()
            } else {
                statusItem.button?.title = "USB ⏸ waiting for drive…"
                miDriveStatus.title = "  Waiting — replug USB drive"
            }
            return
        }

        // ── Paused mode ─────────────────────────────────────────────────
        if copyPaused {
            statusItem.button?.title = "USB ⏸ paused"
            return
        }

        // ── Normal polling ───────────────────────────────────────────────
        let currentMount = findVolumeByUUID(kSurfaceUUID) ?? kVolumePath
        let running   = isDittoRunning()
        let usedBytes = volumeUsedBytes(at: currentMount) ?? 0

        model.addSample(usedBytes)

        let pct   = model.pct
        let speed = model.speedBps
        let eta   = model.etaSeconds
        let phase = model.phase

        let bar   = makeFilledBar(pct: pct, width: 10)
        let label = running
            ? String(format: "USB %@  %02.0f%%", bar, pct)
            : (model.finished ? "USB ✓ done" : "USB ▸ idle")
        statusItem.button?.title = label

        miBar.title    = " \(makeFilledBar(pct: pct, width: 20))  \(String(format: "%02.0f%%", pct))"
        miBar.attributedTitle = barAttrString(miBar.title)
        miDetail.title = "  \(formatBytes(usedBytes))  /  12.0 GB"
        miSpeed.title  = speed > 1000 ? "  \(formatBytes(speed))/s" : "  — MB/s"
        miETA.title    = eta.map { "  ETA  \(formatETA($0))" } ?? "  ETA  —"
        miPhase.title  = "  Phase  \(phase)"
        miVolume.title = "  SURFACE  \(formatBytes(usedBytes)) used  (\(currentMount))"
        miDriveStatus.title = "  Drive: \(currentMount)"

        // Enable pause only when ditto is actively running
        miPauseResume.isEnabled = running || isDittoRunning()

        // APM milestone every 10%
        let milestone = Int(pct / 10) * 10
        if milestone > model.lastMilestone && running {
            model.lastMilestone = milestone
            postAPM(event: "usb_build_progress", data: [
                "timestamp": isoNow(), "pct": Int(pct),
                "used_bytes": Int(usedBytes), "total_bytes": Int(kTotalBytes),
                "speed_bps": Int(speed), "eta_secs": eta.map { Int($0) } as Any,
                "phase": phase, "mount": currentMount
            ])
        }

        // Completion
        if !running && !model.finished && usedBytes > 1_000_000_000 {
            model.finished = true
            let bf = bootFilesPresent(at: currentMount)
            postAPM(event: "usb_build_complete", data: [
                "timestamp": isoNow(), "used_bytes": Int(usedBytes),
                "bootx64_efi": bf.bootx64, "bootmgr_efi": bf.bootmgr,
                "sources_dir": bf.sources, "swm_segments": bf.swmCount,
                "disk": "/dev/disk8", "mount": currentMount
            ])
            statusItem.button?.title = "USB ✓ done — safe to eject"
            miPauseResume.isEnabled = false
            showCompletionNotification(bf: bf, swmCount: bf.swmCount)
            // No auto-eject: user must eject manually to avoid interrupting verification
        }
    }

    // MARK: - Pause / Resume

    @objc private func handlePauseResume(_ sender: NSMenuItem) {
        if copyPaused || waitingForReconnect {
            // Resume path
            if let mount = findVolumeByUUID(kSurfaceUUID) {
                copyPaused = false; waitingForReconnect = false
                sender.title = "Pause copy"
                statusItem.button?.title = "USB ↺ resuming…"
                miDriveStatus.title = "  Drive: \(mount)"
                postAPM(event: "usb_resume_requested", data: ["mount": mount, "timestamp": isoNow()])
                runCopyManager(["resume"])
                model.samples.removeAll()
            } else {
                // Drive not connected — enter waiting mode
                waitingForReconnect = true; copyPaused = false
                sender.title = "Cancel wait"
                statusItem.button?.title = "USB ⏸ waiting…"
                miDriveStatus.title = "  Waiting — replug USB drive"
                postAPM(event: "usb_waiting_for_drive", data: ["uuid": kSurfaceUUID, "timestamp": isoNow()])
            }
        } else {
            // Pause path
            guard isDittoRunning() else { return }
            copyPaused = true
            sender.title = "Resume copy (drive connected)"
            statusItem.button?.title = "USB ⏸ paused"
            postAPM(event: "usb_pause_requested", data: ["timestamp": isoNow()])
            runCopyManager(["pause"])
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        miTitle.isEnabled = false
        let titleFont = NSFont.boldSystemFont(ofSize: 13)
        miTitle.attributedTitle = NSAttributedString(
            string: "Surface Pro 7 — BMR USB",
            attributes: [.font: titleFont])
        menu.addItem(miTitle)
        menu.addItem(.separator())

        miBar.title = " ░░░░░░░░░░░░░░░░░░░░  00%"
        miBar.isEnabled = false
        miBar.attributedTitle = barAttrString(miBar.title)
        menu.addItem(miBar)

        miDetail.title = "  0.0 GB  /  12.0 GB"
        miDetail.isEnabled = false
        menu.addItem(miDetail)

        menu.addItem(.separator())

        miSpeed.title = "  — MB/s"; miSpeed.isEnabled = false; menu.addItem(miSpeed)
        miETA.title   = "  ETA  —"; miETA.isEnabled = false;   menu.addItem(miETA)
        miPhase.title = "  Phase  —"; miPhase.isEnabled = false; menu.addItem(miPhase)

        menu.addItem(.separator())

        miVolume.title = "  SURFACE  — used"; miVolume.isEnabled = false; menu.addItem(miVolume)
        miDriveStatus.title = "  Drive: \(kVolumePath)"; miDriveStatus.isEnabled = false; menu.addItem(miDriveStatus)

        menu.addItem(.separator())

        // Pause / Resume
        miPauseResume = NSMenuItem(title: "Pause copy", action: #selector(handlePauseResume(_:)), keyEquivalent: "p")
        miPauseResume.target = self
        miPauseResume.isEnabled = false
        menu.addItem(miPauseResume)

        let quitOnDoneItem = NSMenuItem(title: "Quit when done", action: #selector(toggleQuitOnDone), keyEquivalent: "")
        quitOnDoneItem.target = self; quitOnDoneItem.state = .on
        menu.addItem(quitOnDoneItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func barAttrString(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        ])
    }

    @objc private func toggleQuitOnDone(_ sender: NSMenuItem) {
        quitOnDone.toggle()
        sender.state = quitOnDone ? .on : .off
    }

    // MARK: - Notification

    private func showCompletionNotification(bf: (bootx64: Bool, bootmgr: Bool, sources: Bool, swmCount: Int), swmCount: Int) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        let ok  = bf.bootx64 && bf.bootmgr && swmCount > 0
        let msg = ok
            ? "Surface Pro 7 BMR USB ready (\(swmCount) WIM segments). Drive ejected."
            : "Copy finished but boot files may be missing — verify before use."
        task.arguments = ["-e", "display notification \"\(msg)\" with title \"USB Monitor\" subtitle \"Write complete\""]
        task.standardOutput = FileHandle.nullDevice
        try? task.run()
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

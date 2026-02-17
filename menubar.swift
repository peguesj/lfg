import Cocoa

class LFGMenubar: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var refreshTimer: Timer?

    // Stats
    var diskFree = "..."
    var diskUsed = "..."
    var reclaimable = "..."
    var backupCount = "..."

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "LFG"
            button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        }

        buildMenu()
        refreshStats()

        // Refresh every 5 minutes
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshStats()
        }
    }

    func buildMenu() {
        menu = NSMenu()

        // Header
        let header = NSMenuItem(title: "LFG - Local File Guardian", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(
            string: "LFG - Local File Guardian",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)]
        )
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // Stats section
        menu.addItem(makeStatItem("Disk Free", value: diskFree, color: .systemBlue))
        menu.addItem(makeStatItem("Disk Used", value: diskUsed, color: .secondaryLabelColor))
        menu.addItem(makeStatItem("Reclaimable", value: reclaimable, color: .systemOrange))
        menu.addItem(makeStatItem("Backups", value: backupCount, color: .systemGreen))
        menu.addItem(NSMenuItem.separator())

        // Module launchers
        let wtfs = NSMenuItem(title: "WTFS - Disk Usage", action: #selector(openWTFS), keyEquivalent: "1")
        wtfs.target = self
        menu.addItem(wtfs)

        let dtf = NSMenuItem(title: "DTF - Cache Cleanup", action: #selector(openDTF), keyEquivalent: "2")
        dtf.target = self
        menu.addItem(dtf)

        let btau = NSMenuItem(title: "BTAU - Backup Status", action: #selector(openBTAU), keyEquivalent: "3")
        btau.target = self
        menu.addItem(btau)

        menu.addItem(NSMenuItem.separator())

        let dash = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dash.target = self
        menu.addItem(dash)

        let apm = NSMenuItem(title: "Open APM Monitor", action: #selector(openAPM), keyEquivalent: "m")
        apm.target = self
        menu.addItem(apm)

        menu.addItem(NSMenuItem.separator())

        let refresh = NSMenuItem(title: "Refresh Stats", action: #selector(doRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "Quit LFG Menubar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
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

    func refreshStats() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let disk = Self.shell("df -h / | awk 'NR==2{print $4 \"|\" $5}'")
            let parts = disk.split(separator: "|")
            let free = parts.count > 0 ? String(parts[0]) : "?"
            let used = parts.count > 1 ? String(parts[1]) : "?"

            let reclaim = Self.shell("du -sk ~/.npm ~/.cache/uv ~/.cargo/registry ~/Library/Caches/Homebrew ~/Library/Caches/Google ~/Library/Caches/com.spotify.client ~/Library/Developer/Xcode/DerivedData 2>/dev/null | awk '{s+=$1}END{if(s>=1048576)printf \"%.1fG\",s/1048576; else if(s>=1024)printf \"%.0fM\",s/1024; else printf \"%dK\",s}'")

            let backups = Self.shell("python3 -c \"import json; m=json.load(open('\\(NSHomeDirectory())/.config/btau/manifest.json')); print(len(m.get('history',[])))\" 2>/dev/null || echo '0'")

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.diskFree = free
                self.diskUsed = used
                self.reclaimable = reclaim.isEmpty ? "0" : reclaim
                self.backupCount = backups.trimmingCharacters(in: .whitespacesAndNewlines)

                // Update menubar title
                if let button = self.statusItem.button {
                    button.title = "LFG \(free)"
                }

                // Rebuild menu with fresh stats
                self.buildMenu()
            }
        }
    }

    static func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.arguments = ["-c", command]
        task.launchPath = "/bin/bash"
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func launchLFG(_ args: String) {
        let lfgPath = "\(NSHomeDirectory())/tools/@yj/lfg/lfg"
        DispatchQueue.global(qos: .userInitiated).async {
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
    @objc func openAPM() {
        NSWorkspace.shared.open(URL(string: "http://localhost:3031")!)
    }
    @objc func doRefresh() { refreshStats() }
}

let delegate = LFGMenubar()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)  // No dock icon
app.run()

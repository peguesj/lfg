import Cocoa
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView!
    let htmlPath: String
    let windowTitle: String
    let selectionFile: String?
    var navigationStack: [URL] = []

    init(htmlPath: String, windowTitle: String, selectionFile: String?) {
        self.htmlPath = htmlPath
        self.windowTitle = windowTitle
        self.selectionFile = selectionFile
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let width: CGFloat = min(880, screenFrame.width * 0.65)
        let height: CGFloat = min(750, screenFrame.height * 0.85)
        let x = screenFrame.origin.x + (screenFrame.width - width) / 2
        let y = screenFrame.origin.y + (screenFrame.height - height) / 2

        window = NSWindow(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = windowTitle
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 500, height: 400)

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Register JS->native message handler
        config.userContentController.add(self, name: "lfg")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        window.contentView = webView

        let url = URL(fileURLWithPath: htmlPath)
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Handle messages from JavaScript
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "lfg",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        // Helper to read string values from body
        func str(_ key: String) -> String? { body[key] as? String }

        if action == "exec", let cmd = str("cmd"), let reqId = str("id") {
            // Execute a shell command and return results to JS
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let task = Process()
                task.launchPath = "/bin/bash"
                task.arguments = ["-c", cmd]
                let outPipe = Pipe()
                let errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe
                do {
                    try task.run()
                    task.waitUntilExit()
                } catch {
                    DispatchQueue.main.async {
                        let js = "LFG._onExecResult('\(reqId)', '', 'Process launch failed: \(error.localizedDescription)', 1)"
                        self?.webView.evaluateJavaScript(js, completionHandler: nil)
                    }
                    return
                }
                let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let code = task.terminationStatus
                DispatchQueue.main.async {
                    // Escape for JS string literal
                    func esc(_ s: String) -> String {
                        s.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "'", with: "\\'")
                         .replacingOccurrences(of: "\n", with: "\\n")
                         .replacingOccurrences(of: "\r", with: "\\r")
                    }
                    let js = "LFG._onExecResult('\(reqId)', '\(esc(stdout))', '\(esc(stderr))', \(code))"
                    self?.webView.evaluateJavaScript(js, completionHandler: nil)
                }
            }
        } else if action == "confirm", let msg = str("message"), let cmd = str("cmd"), let reqId = str("id") {
            // Show native confirm dialog, then execute if approved
            let alert = NSAlert()
            alert.messageText = "Confirm Action"
            alert.informativeText = msg
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Execute")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                // Repost as exec
                // Execute the confirmed command
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let task = Process()
                    task.launchPath = "/bin/bash"
                    task.arguments = ["-c", cmd]
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    task.standardOutput = outPipe
                    task.standardError = errPipe
                    do { try task.run(); task.waitUntilExit() } catch { return }
                    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let code = task.terminationStatus
                    DispatchQueue.main.async {
                        func esc(_ s: String) -> String {
                            s.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "'", with: "\\'")
                             .replacingOccurrences(of: "\n", with: "\\n")
                             .replacingOccurrences(of: "\r", with: "\\r")
                        }
                        let js = "LFG._onExecResult('\(reqId)', '\(esc(stdout))', '\(esc(stderr))', \(code))"
                        self?.webView.evaluateJavaScript(js, completionHandler: nil)
                    }
                }
            } else {
                let js = "LFG._onExecResult('\(reqId)', '', 'User cancelled', -1)"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        } else if action == "select", let module = str("module"), let path = selectionFile {
            try? module.write(toFile: path, atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSApp.terminate(nil)
            }
        } else if action == "navigate", let target = str("target") {
            // In-place navigation: push current URL and load new HTML
            let lfgDir = NSHomeDirectory() + "/tools/@yj/lfg"
            let targetPath: String
            switch target {
            case "wtfs":      targetPath = lfgDir + "/.lfg_scan.html"
            case "dtf":       targetPath = lfgDir + "/.lfg_clean.html"
            case "btau":      targetPath = lfgDir + "/.lfg_btau.html"
            case "devdrive":  targetPath = lfgDir + "/.lfg_devdrive.html"
            case "stfu":      targetPath = lfgDir + "/.lfg_stfu.html"
            case "dashboard": targetPath = lfgDir + "/.lfg_dashboard.html"
            case "splash":    targetPath = lfgDir + "/.lfg_splash.html"
            default:          targetPath = target  // allow direct file paths
            }
            // Generate the target HTML if it doesn't exist yet (run the module)
            if !FileManager.default.fileExists(atPath: targetPath) {
                let modName = target
                let cmd = "\(lfgDir)/lfg \(modName) 2>/dev/null; true"
                let task = Process()
                task.launchPath = "/bin/bash"
                task.arguments = ["-c", cmd]
                try? task.run()
                task.waitUntilExit()
            }
            if let currentURL = webView.url {
                navigationStack.append(currentURL)
            }
            let targetURL = URL(fileURLWithPath: targetPath)
            webView.loadFileURL(targetURL, allowingReadAccessTo: targetURL.deletingLastPathComponent())
            syncNavDepth()
        } else if action == "back" {
            if let prev = navigationStack.popLast() {
                webView.loadFileURL(prev, allowingReadAccessTo: prev.deletingLastPathComponent())
                syncNavDepth()
            }
        } else if action == "home" {
            let splashPath = NSHomeDirectory() + "/tools/@yj/lfg/.lfg_splash.html"
            navigationStack.removeAll()
            let splashURL = URL(fileURLWithPath: splashPath)
            webView.loadFileURL(splashURL, allowingReadAccessTo: splashURL.deletingLastPathComponent())
            syncNavDepth()
        } else if action == "run", let module = str("module") {
            let lfgPath = NSHomeDirectory() + "/tools/@yj/lfg/lfg"
            let args = str("args") ?? ""
            let cmd = args.isEmpty ? "\(lfgPath) \(module)" : "\(lfgPath) \(module) \(args)"
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.launchPath = "/bin/bash"
                task.arguments = ["-c", cmd]
                try? task.run()
            }
        } else if action == "quit" {
            NSApp.terminate(nil)
        }
    }

    /// Sync navigation stack depth to JS so back button visibility can update
    func syncNavDepth() {
        webView.evaluateJavaScript("window.__lfgNavDepth = \(navigationStack.count)") { _, _ in
            self.webView.evaluateJavaScript("if(typeof LFG !== 'undefined' && LFG._updateNavButtons) LFG._updateNavButtons()", completionHandler: nil)
        }
    }

    @objc func reloadPage() {
        webView.reload()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool {
        return true
    }
}

// Parse args: viewer <html> [title] [--select <file>]
let args = CommandLine.arguments
guard args.count > 1 else {
    print("Usage: viewer <html-file> [window-title] [--select <selection-file>]")
    exit(1)
}

let htmlPath = args[1]
var windowTitle = "LFG - Local File Guardian"
var selectionFile: String? = nil

var i = 2
while i < args.count {
    if args[i] == "--select" && i + 1 < args.count {
        selectionFile = args[i + 1]
        i += 2
    } else {
        windowTitle = args[i]
        i += 1
    }
}

let delegate = AppDelegate(htmlPath: htmlPath, windowTitle: windowTitle, selectionFile: selectionFile)
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)

// Build main menu bar so app shows as "LFG" not "viewer"
let mainMenu = NSMenu()

// App menu (LFG)
let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About LFG", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit LFG", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)

// File menu
let fileMenuItem = NSMenuItem()
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
fileMenuItem.submenu = fileMenu
mainMenu.addItem(fileMenuItem)

// View menu
let viewMenuItem = NSMenuItem()
let viewMenu = NSMenu(title: "View")
viewMenu.addItem(withTitle: "Reload", action: #selector(AppDelegate.reloadPage), keyEquivalent: "r")
viewMenu.addItem(withTitle: "Actual Size", action: nil, keyEquivalent: "0")
viewMenu.addItem(withTitle: "Zoom In", action: nil, keyEquivalent: "+")
viewMenu.addItem(withTitle: "Zoom Out", action: nil, keyEquivalent: "-")
viewMenu.addItem(NSMenuItem.separator())
viewMenu.addItem(withTitle: "Toggle Developer Tools", action: nil, keyEquivalent: "")
viewMenuItem.submenu = viewMenu
mainMenu.addItem(viewMenuItem)

// Help menu
let helpMenuItem = NSMenuItem()
let helpMenu = NSMenu(title: "Help")
helpMenu.addItem(withTitle: "LFG Documentation", action: nil, keyEquivalent: "")
helpMenu.addItem(withTitle: "Report Issue", action: nil, keyEquivalent: "")
helpMenuItem.submenu = helpMenu
mainMenu.addItem(helpMenuItem)

app.mainMenu = mainMenu
app.run()

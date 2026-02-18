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

    // Module display names for window title
    static let moduleNames: [String: String] = [
        "wtfs": "WTFS - Where's The Free Space",
        "dtf": "DTF - Delete Temp Files",
        "btau": "BTAU - Back That App Up",
        "devdrive": "DEVDRIVE - Developer Drive",
        "stfu": "STFU - Source Tree Forensics",
        "dashboard": "LFG Dashboard",
        "splash": "LFG - Local File Guardian"
    ]

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

        // Capture the originating webView for routing responses
        let sourceWebView: WKWebView = message.webView ?? webView

        if action == "exec", let cmd = str("cmd"), let reqId = str("id") {
            // Execute a shell command and return results to JS
            DispatchQueue.global(qos: .userInitiated).async {
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
                        sourceWebView.evaluateJavaScript(js, completionHandler: nil)
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
                    sourceWebView.evaluateJavaScript(js, completionHandler: nil)
                }
            }
        } else if action == "confirm", let msg = str("message"), let cmd = str("cmd"), let reqId = str("id") {
            let alert = NSAlert()
            alert.messageText = "Confirm Action"
            alert.informativeText = msg
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Execute")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                DispatchQueue.global(qos: .userInitiated).async {
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
                        sourceWebView.evaluateJavaScript(js, completionHandler: nil)
                    }
                }
            } else {
                let js = "LFG._onExecResult('\(reqId)', '', 'User cancelled', -1)"
                sourceWebView.evaluateJavaScript(js, completionHandler: nil)
            }
        } else if action == "select", let module = str("module"), let path = selectionFile {
            try? module.write(toFile: path, atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSApp.terminate(nil)
            }
        } else if action == "navigate", let target = str("target") {
            // In-place navigation with loading screen
            let lfgDir = NSHomeDirectory() + "/tools/@yj/lfg"
            let targetPath: String
            let moduleCmd: String?
            switch target {
            case "wtfs":      targetPath = lfgDir + "/.lfg_scan.html"; moduleCmd = "wtfs"
            case "dtf":       targetPath = lfgDir + "/.lfg_clean.html"; moduleCmd = "dtf"
            case "btau":      targetPath = lfgDir + "/.lfg_btau.html"; moduleCmd = "btau"
            case "devdrive":  targetPath = lfgDir + "/.lfg_devdrive.html"; moduleCmd = "devdrive"
            case "stfu":      targetPath = lfgDir + "/.lfg_stfu.html"; moduleCmd = "stfu"
            case "dashboard": targetPath = lfgDir + "/.lfg_dashboard.html"; moduleCmd = "dashboard"
            case "splash":    targetPath = lfgDir + "/.lfg_splash.html"; moduleCmd = nil
            default:          targetPath = target; moduleCmd = nil
            }

            // Update window title
            let displayName = AppDelegate.moduleNames[target] ?? windowTitle
            window.title = displayName

            // Push current URL to nav stack
            if let currentURL = webView.url {
                navigationStack.append(currentURL)
            }

            // If file exists already, load it directly
            if FileManager.default.fileExists(atPath: targetPath) && moduleCmd == nil {
                let targetURL = URL(fileURLWithPath: targetPath)
                webView.loadFileURL(targetURL, allowingReadAccessTo: targetURL.deletingLastPathComponent())
                syncNavDepth()
                return
            }

            // Show loading screen inline, then generate in background
            let colors: [String: String] = [
                "wtfs": "#4a9eff", "dtf": "#ff8c42", "btau": "#06d6a0",
                "devdrive": "#c084fc", "stfu": "#e879f9", "dashboard": "#4a9eff"
            ]
            let labels: [String: String] = [
                "wtfs": "Scanning disk usage...", "dtf": "Discovering caches...",
                "btau": "Checking backups...", "devdrive": "Loading developer drive...",
                "stfu": "Analyzing source trees...", "dashboard": "Building dashboard..."
            ]
            let accentColor = colors[target] ?? "#4a9eff"
            let loadingLabel = labels[target] ?? "Loading..."
            let modTitle = (target == "dashboard") ? "Dashboard" : target.uppercased()

            let loadingHTML = """
            <!DOCTYPE html><html><head><meta charset="utf-8"><style>
            *{margin:0;padding:0;box-sizing:border-box}
            body{font-family:-apple-system,BlinkMacSystemFont,"SF Mono",Menlo,monospace;
              background:#141418;color:#e0e0e6;display:flex;flex-direction:column;
              align-items:center;justify-content:center;min-height:100vh;overflow:hidden}
            .loader{text-align:center;animation:fadeIn 0.3s ease-out}
            @keyframes fadeIn{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}
            .brand{font-size:48px;font-weight:800;letter-spacing:-2px;color:#fff;margin-bottom:2px}
            .brand span{color:\(accentColor)}
            .mod-name{font-size:13px;font-weight:600;color:\(accentColor);letter-spacing:2px;
              text-transform:uppercase;margin-bottom:32px}
            .track{width:240px;height:3px;background:#1e1e28;border-radius:2px;overflow:hidden;margin-bottom:16px}
            .fill{height:100%;width:30%;background:\(accentColor);border-radius:2px;
              animation:shimmer 1.8s cubic-bezier(0.22,1,0.36,1) infinite}
            @keyframes shimmer{0%{width:0%;margin-left:0}50%{width:60%;margin-left:20%}100%{width:0%;margin-left:100%}}
            .label{font-size:12px;color:#6b6b78;margin-bottom:24px}
            .skeleton{display:flex;flex-direction:column;gap:10px;width:320px;opacity:0.4}
            .skel-row{height:10px;background:#1e1e28;border-radius:4px;animation:pulse 1.5s ease-in-out infinite}
            .skel-row:nth-child(1){width:100%}
            .skel-row:nth-child(2){width:85%;animation-delay:0.15s}
            .skel-row:nth-child(3){width:70%;animation-delay:0.3s}
            .skel-row:nth-child(4){width:90%;animation-delay:0.45s}
            @keyframes pulse{0%,100%{opacity:0.3}50%{opacity:0.6}}
            .glow{position:fixed;width:300px;height:300px;border-radius:50%;
              background:radial-gradient(circle,\(accentColor)10 0%,transparent 70%);
              opacity:0.06;top:50%;left:50%;transform:translate(-50%,-50%);
              animation:breathe 3s ease-in-out infinite}
            @keyframes breathe{0%,100%{transform:translate(-50%,-50%) scale(1)}50%{transform:translate(-50%,-50%) scale(1.15)}}
            </style></head><body>
            <div class="glow"></div>
            <div class="loader">
              <div class="brand"><span>L</span>F<span>G</span></div>
              <div class="mod-name">\(modTitle)</div>
              <div class="track"><div class="fill"></div></div>
              <div class="label">\(loadingLabel)</div>
              <div class="skeleton">
                <div class="skel-row"></div><div class="skel-row"></div>
                <div class="skel-row"></div><div class="skel-row"></div>
              </div>
            </div>
            </body></html>
            """

            webView.loadHTMLString(loadingHTML, baseURL: nil)
            syncNavDepth()

            // Generate module HTML in background (LFG_NO_VIEWER suppresses viewer launch)
            let cmd = "LFG_NO_VIEWER=1 \(lfgDir)/lfg \(moduleCmd ?? target) 2>/dev/null; true"
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let task = Process()
                task.launchPath = "/bin/bash"
                task.arguments = ["-c", cmd]
                try? task.run()
                task.waitUntilExit()
                DispatchQueue.main.async {
                    let targetURL = URL(fileURLWithPath: targetPath)
                    let lfgDirURL = URL(fileURLWithPath: lfgDir)
                    self?.webView.loadFileURL(targetURL, allowingReadAccessTo: lfgDirURL)
                }
            }
        } else if action == "back" {
            if let prev = navigationStack.popLast() {
                webView.loadFileURL(prev, allowingReadAccessTo: prev.deletingLastPathComponent())
                syncNavDepth()
            }
        } else if action == "home" {
            let splashPath = NSHomeDirectory() + "/tools/@yj/lfg/.lfg_splash.html"
            navigationStack.removeAll()
            window.title = "LFG - Local File Guardian"
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
        } else if action == "close-settings" {
            if let sw = settingsWindow {
                window.endSheet(sw)
                settingsWindow = nil
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

    @objc func openSettings() {
        // Navigate to settings via the LFG settings command, rendered in a sheet-style panel
        let lfgDir = NSHomeDirectory() + "/tools/@yj/lfg"
        let settingsHTML = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,"SF Mono",Menlo,monospace;
          background:#141418;color:#e0e0e6;padding:32px;-webkit-font-smoothing:antialiased}
        h1{font-size:18px;font-weight:700;color:#fff;margin-bottom:20px}
        h1 span{color:#4a9eff}
        .section{margin-bottom:24px}
        .section-title{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:1px;
          color:#4a9eff;margin-bottom:10px;padding-bottom:4px;border-bottom:1px solid #1e1e28}
        .row{display:flex;justify-content:space-between;align-items:center;padding:10px 0;
          border-bottom:1px solid #1e1e28;font-size:12px}
        .row:last-child{border-bottom:none}
        .row label{color:#a0a0b0}
        .row input,.row select{background:#2a2a34;border:1px solid #3a3a44;border-radius:4px;
          color:#e0e0e6;padding:5px 10px;font-size:11px;font-family:inherit;outline:none;width:200px}
        .row input:focus,.row select:focus{border-color:#4a9eff}
        .paths-list{margin:8px 0;font-size:11px}
        .path-item{display:flex;align-items:center;gap:8px;padding:6px 10px;background:#1c1c22;
          border:1px solid #2a2a34;border-radius:6px;margin-bottom:4px}
        .path-item .p{flex:1;color:#e0e0e6;font-family:monospace;font-size:11px}
        .path-item button{background:none;border:1px solid #ff4d6a33;color:#ff4d6a;
          border-radius:4px;padding:2px 8px;font-size:10px;cursor:pointer}
        .add-row{display:flex;gap:6px;margin-top:6px}
        .add-row input{flex:1}
        .add-row button{background:#4a9eff15;border:1px solid #4a9eff33;color:#4a9eff;
          border-radius:4px;padding:4px 12px;font-size:11px;cursor:pointer}
        .access-grid{display:grid;grid-template-columns:repeat(5,1fr);gap:6px;margin-top:8px}
        .access-chip{text-align:center;padding:6px;background:#1c1c22;border:1px solid #2a2a34;
          border-radius:6px;font-size:10px;cursor:pointer;transition:all 0.15s}
        .access-chip.on{border-color:#06d6a0;color:#06d6a0;background:rgba(6,214,160,0.08)}
        .access-chip .mod{font-weight:700;display:block;margin-bottom:2px}
        .btn-bar{display:flex;gap:8px;margin-top:20px}
        .btn{padding:8px 20px;border-radius:6px;font-size:12px;font-weight:600;cursor:pointer;
          font-family:inherit;border:1px solid #2a2a34;background:transparent;color:#a0a0b0;transition:all 0.15s}
        .btn:hover{border-color:#4a9eff;color:#4a9eff}
        .btn.primary{background:#4a9eff;border-color:#4a9eff;color:#fff}
        .btn.primary:hover{background:#3a8eef}
        .btn.danger{border-color:#ff4d6a33;color:#ff4d6a}
        .btn.danger:hover{border-color:#ff4d6a;background:rgba(255,77,106,0.08)}
        .toast{position:fixed;bottom:20px;right:20px;padding:10px 16px;background:#1c2d24;
          border:1px solid #06d6a0;border-radius:8px;font-size:12px;color:#06d6a0;
          opacity:0;transition:opacity 0.3s;pointer-events:none}
        .toast.show{opacity:1}
        #loading{text-align:center;padding:40px;color:#6b6b78}
        </style></head><body>
        <h1><span>LFG</span> Settings</h1>
        <div id="loading">Loading settings...</div>
        <div id="content" style="display:none">
          <div class="section">
            <div class="section-title">Scan Paths</div>
            <div id="paths-list" class="paths-list"></div>
            <div class="add-row">
              <input id="new-path" type="text" placeholder="~/path/to/projects">
              <button onclick="addPath()">Add</button>
            </div>
          </div>
          <div class="section">
            <div class="section-title">Library Namespace</div>
            <div class="row">
              <label>Package scope for STFU scaffolds</label>
              <input id="namespace" type="text" value="@jeremiah" onchange="saveSetting('library_namespace', this.value)">
            </div>
          </div>
          <div class="section">
            <div class="section-title">Module Access</div>
            <p style="font-size:11px;color:#6b6b78;margin-bottom:8px">Which modules can access each scan path</p>
            <div id="access-grid" class="access-grid"></div>
          </div>
          <div class="btn-bar">
            <button class="btn danger" onclick="resetDefaults()">Reset Defaults</button>
            <span style="flex:1"></span>
            <button class="btn" onclick="window.webkit.messageHandlers.lfg.postMessage({action:'close-settings'})">Done</button>
          </div>
        </div>
        <div id="toast" class="toast"></div>
        <script>
        var settings = {};
        function toast(msg) {
          var t = document.getElementById('toast'); t.textContent = msg;
          t.classList.add('show'); setTimeout(function(){t.classList.remove('show')}, 2000);
        }
        function exec(cmd, cb) {
          window.webkit.messageHandlers.lfg.postMessage({action:'exec',cmd:cmd,id:'s_'+(++window._sid)});
          window._scb['s_'+window._sid] = cb;
        }
        window._sid = 0; window._scb = {};
        window.LFG = { _onExecResult: function(id,out,err,code){ if(window._scb[id]){window._scb[id](out,err,code);delete window._scb[id];} } };

        function loadSettings() {
          exec('\\(lfgDir)/lfg settings show --json', function(out) {
            try { settings = JSON.parse(out); } catch(e) { settings = {}; }
            document.getElementById('loading').style.display = 'none';
            document.getElementById('content').style.display = 'block';
            renderPaths();
            document.getElementById('namespace').value = settings.library_namespace || '@jeremiah';
            renderAccess();
          });
        }
        function renderPaths() {
          var el = document.getElementById('paths-list');
          var paths = settings.scan_paths || ['~/Developer'];
          el.innerHTML = paths.map(function(p){
            return '<div class="path-item"><span class="p">'+p+'</span>'
              +'<button onclick="removePath(\\''+p+'\\')">Remove</button></div>';
          }).join('');
        }
        function addPath() {
          var p = document.getElementById('new-path').value.trim();
          if (!p) return;
          exec('\\(lfgDir)/lfg settings paths add "'+p+'"', function(){ document.getElementById('new-path').value=''; toast('Path added'); reloadSettings(); });
        }
        function removePath(p) {
          exec('\\(lfgDir)/lfg settings paths remove "'+p+'"', function(){ toast('Path removed'); reloadSettings(); });
        }
        function saveSetting(key, val) {
          exec('\\(lfgDir)/lfg settings set '+key+' "'+val+'"', function(){ toast('Saved'); });
        }
        function renderAccess() {
          var mods = ['wtfs','dtf','btau','devdrive','stfu'];
          var access = settings.module_access || {};
          var el = document.getElementById('access-grid');
          el.innerHTML = mods.map(function(m){
            var on = (access[m] || 'all') === 'all';
            return '<div class="access-chip '+(on?'on':'')+'" onclick="toggleAccess(\\''+m+'\\')"><span class="mod">'+m.toUpperCase()+'</span>'+(on?'All Paths':'Limited')+'</div>';
          }).join('');
        }
        function toggleAccess(mod) {
          var cur = (settings.module_access || {})[mod] || 'all';
          var next = cur === 'all' ? 'none' : 'all';
          exec('\\(lfgDir)/lfg settings set module_access.'+mod+' '+next, function(){ toast(mod.toUpperCase()+' access: '+next); reloadSettings(); });
        }
        function resetDefaults() {
          exec('\\(lfgDir)/lfg settings reset', function(){ toast('Reset to defaults'); reloadSettings(); });
        }
        function reloadSettings() { loadSettings(); }
        loadSettings();
        </script></body></html>
        """

        // Open settings in a new sheet window
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "LFG Settings"
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.userContentController.add(self, name: "lfg")

        let settingsWebView = WKWebView(frame: .zero, configuration: config)
        settingsWebView.setValue(false, forKey: "drawsBackground")
        settingsWindow.contentView = settingsWebView
        settingsWebView.loadHTMLString(settingsHTML, baseURL: nil)

        window.beginSheet(settingsWindow) { _ in }
        self.settingsWindow = settingsWindow
    }

    var settingsWindow: NSWindow?

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
appMenu.addItem(withTitle: "Settings...", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
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

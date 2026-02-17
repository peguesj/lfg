import Cocoa
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: WKWebView!
    let htmlPath: String
    let windowTitle: String
    let selectionFile: String?

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
              let body = message.body as? [String: String],
              let action = body["action"] else { return }

        if action == "select", let module = body["module"], let path = selectionFile {
            // Write selection to file so the shell script can pick it up
            try? module.write(toFile: path, atomically: true, encoding: .utf8)
            // Close after brief delay for the loading animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSApp.terminate(nil)
            }
        } else if action == "quit" {
            NSApp.terminate(nil)
        }
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
app.run()

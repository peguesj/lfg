import AppKit
import WebKit
import Foundation
import LFGKit

// MARK: - VolumeDetectWindowController

/// Floating window that shows a loading animation while waiting for a specific
/// external host drive (e.g. "YJ_MORE") to be connected.
///
/// When the host mounts, the controller:
/// 1. Animates "Connected" in the web view.
/// 2. Triggers `MountOrchestrator.attachAll(forHost:)` to mount the sparseimages.
/// 3. Closes itself after a short success delay.
///
/// Opening:
/// ```swift
/// VolumeDetectWindowController.show(waitingForHost: "YJ_MORE", volumeIds: ["901DEVLIB"])
/// ```
@MainActor
final class VolumeDetectWindowController: NSWindowController, WKScriptMessageHandler {

    private static var instances: [String: VolumeDetectWindowController] = [:]

    private var webView: WKWebView!
    private var mountObserver: NSObjectProtocol?
    private let hostName: String
    private let volumeIds: [String]

    private let fleetURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("DevDrive/fleet.json")

    // MARK: - Factory

    /// Show the detect window for `hostName`. Idempotent — brings existing window to front.
    static func show(waitingForHost hostName: String, volumeIds: [String]) {
        if let existing = instances[hostName] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = VolumeDetectWindowController(hostName: hostName, volumeIds: volumeIds)
        instances[hostName] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Init

    init(hostName: String, volumeIds: [String]) {
        self.hostName = hostName
        self.volumeIds = volumeIds

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.center()

        super.init(window: panel)

        setupWebView(in: panel)
        setupMountObserver()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let obs = mountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - WebView

    private func setupWebView(in panel: NSPanel) {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(self, name: "lfgDetect")
        config.userContentController = controller

        let wv = WKWebView(frame: panel.contentView!.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        panel.contentView!.addSubview(wv)
        self.webView = wv

        loadDetectHTML()
    }

    private func loadDetectHTML() {
        let lfgDir = (Bundle.main.bundlePath as NSString)
            .deletingLastPathComponent   // up from Contents/MacOS
            // fall back to source tree location when running in SPM
        let htmlPaths = [
            "\(lfgDir)/assets/devdrive-detect.html",
            "\(NSHomeDirectory())/tools/@yj/lfg/assets/devdrive-detect.html"
        ]
        for path in htmlPaths {
            if FileManager.default.fileExists(atPath: path),
               let html = try? String(contentsOfFile: path, encoding: .utf8) {
                let populated = html
                    .replacingOccurrences(of: "{{HOST_NAME}}", with: hostName)
                    .replacingOccurrences(of: "{{VOLUME_IDS}}", with: volumeIds.joined(separator: ", "))
                let baseURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
                webView.loadHTMLString(populated, baseURL: baseURL)
                return
            }
        }
        // Inline fallback if asset not found.
        webView.loadHTMLString(inlineFallbackHTML(), baseURL: nil)
    }

    // MARK: - Mount observer

    private func setupMountObserver() {
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let name = notification.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String,
                  name == self.hostName else { return }
            Task { @MainActor [weak self] in self?.handleHostMounted() }
        }
    }

    private func handleHostMounted() {
        // Signal the web view to show success animation.
        webView.evaluateJavaScript("window.lfgHostConnected && window.lfgHostConnected()") { _, _ in }

        // Trigger attach via MountOrchestrator.
        Task { @MainActor in
            guard let registry = try? FleetRegistry(url: fleetURL) else { return }
            let orchestrator = MountOrchestrator(registry: registry)
            _ = await orchestrator.attachAll(forHost: hostName)

            // Close after 2 s so the user sees the success state.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.close()
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let action = message.body as? String else { return }
        switch action {
        case "dismiss":
            close()
        case "openFallback":
            close()
            FallbackVolumeWindowController.show(volumeIds: volumeIds)
        default:
            break
        }
    }

    // MARK: - Close

    override func close() {
        Self.instances.removeValue(forKey: hostName)
        super.close()
    }

    // MARK: - Inline fallback HTML

    private func inlineFallbackHTML() -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
        body{margin:0;background:#111;color:#e5e7eb;font-family:system-ui;display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;gap:16px}
        .spinner{width:40px;height:40px;border:3px solid #374151;border-top-color:#22d3ee;border-radius:50%;animation:spin 1s linear infinite}
        @keyframes spin{to{transform:rotate(360deg)}}
        h2{font-size:16px;font-weight:600;margin:0}
        p{font-size:13px;color:#9ca3af;margin:0}
        button{margin-top:8px;padding:6px 14px;background:#1f2937;border:1px solid #374151;color:#e5e7eb;border-radius:6px;cursor:pointer;font-size:12px}
        </style></head><body>
        <div class="spinner"></div>
        <h2>Waiting for \(hostName)…</h2>
        <p>Connect the drive to mount: \(volumeIds.joined(separator: ", "))</p>
        <button onclick="webkit.messageHandlers.lfgDetect.postMessage('openFallback')">Use Different Volume</button>
        <button onclick="webkit.messageHandlers.lfgDetect.postMessage('dismiss')">Dismiss</button>
        </body></html>
        """
    }
}

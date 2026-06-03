import AppKit
import WebKit
import Foundation
import LFGKit

// MARK: - FallbackVolumeWindowController

/// Floating window showing the fallback volume management UI.
///
/// The HTML view communicates back via `WKScriptMessageHandler` with a JSON
/// payload that maps to `FallbackPolicy`. Changes are persisted to
/// `~/.config/lfg/fallback_policy.json` immediately.
///
/// Opening:
/// ```swift
/// FallbackVolumeWindowController.show(volumeIds: ["901DEVLIB", "904MEMVT"])
/// ```
@MainActor
final class FallbackVolumeWindowController: NSWindowController, WKScriptMessageHandler {

    private static var instance: FallbackVolumeWindowController?

    private var webView: WKWebView!
    private let volumeIds: [String]

    private let fleetURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("DevDrive/fleet.json")

    // MARK: - Factory

    static func show(volumeIds: [String]) {
        if let existing = instance {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = FallbackVolumeWindowController(volumeIds: volumeIds)
        instance = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Init

    init(volumeIds: [String]) {
        self.volumeIds = volumeIds

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "DevDrive — Fallback Volume"
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.center()

        super.init(window: panel)

        setupWebView(in: panel)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - WebView

    private func setupWebView(in panel: NSPanel) {
        let config = WKWebViewConfiguration()
        let uc = WKUserContentController()
        uc.add(self, name: "lfgFallback")
        config.userContentController = uc

        let wv = WKWebView(frame: panel.contentView!.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        panel.contentView!.addSubview(wv)
        self.webView = wv

        loadFallbackHTML()
    }

    private func loadFallbackHTML() {
        // Collect available volumes from fleet.json to populate the picker.
        let availableVolumes: [(id: String, purpose: String, mounted: Bool)]
        if let registry = try? FleetRegistry(url: fleetURL) {
            let fm = FileManager.default
            availableVolumes = registry.allVolumeBackends.map { b in
                (id: b.id, purpose: b.purpose ?? b.id, mounted: fm.fileExists(atPath: b.mount))
            }
        } else {
            availableVolumes = []
        }

        let existingPolicy = FallbackPolicy.load()

        let htmlPaths = [
            "\(NSHomeDirectory())/tools/@yj/lfg/assets/devdrive-fallback-mgmt.html"
        ]
        for path in htmlPaths {
            if FileManager.default.fileExists(atPath: path),
               let html = try? String(contentsOfFile: path, encoding: .utf8) {
                // Inject runtime data via JS.
                let volJSON = (try? String(
                    data: JSONEncoder().encode(availableVolumes.map { ["id": $0.id, "purpose": $0.purpose, "mounted": $0.mounted ? "true" : "false"] }),
                    encoding: .utf8
                )) ?? "[]"
                let policyJSON = (try? String(
                    data: JSONEncoder().encode(existingPolicy),
                    encoding: .utf8
                )) ?? "{}"
                let targetIdsJSON = (try? String(
                    data: JSONEncoder().encode(volumeIds),
                    encoding: .utf8
                )) ?? "[]"
                let injected = html
                    .replacingOccurrences(of: "{{AVAILABLE_VOLUMES_JSON}}", with: volJSON)
                    .replacingOccurrences(of: "{{EXISTING_POLICY_JSON}}", with: policyJSON)
                    .replacingOccurrences(of: "{{TARGET_VOLUME_IDS_JSON}}", with: targetIdsJSON)
                let baseURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
                webView.loadHTMLString(injected, baseURL: baseURL)
                return
            }
        }
        webView.loadHTMLString(inlineFallbackHTML(availableVolumes: availableVolumes), baseURL: nil)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let raw = message.body as? String,
              let data = raw.data(using: .utf8) else { return }

        if let action = try? JSONDecoder().decode(FallbackAction.self, from: data) {
            handleAction(action)
        }
    }

    // MARK: - Action dispatch

    private func handleAction(_ action: FallbackAction) {
        switch action.type {
        case "save":
            savePolicy(from: action)
        case "dismiss":
            close()
        case "openDetect":
            close()
            if let host = action.hostName {
                VolumeDetectWindowController.show(waitingForHost: host, volumeIds: action.volumeIds ?? volumeIds)
            }
        default:
            break
        }
    }

    private func savePolicy(from action: FallbackAction) {
        var policy = FallbackPolicy.load()

        for volId in action.volumeIds ?? volumeIds {
            var override = policy.volumeOverrides[volId] ?? FallbackPolicy.VolumeOverride()

            if let fallbackId = action.fallbackVolumeId {
                override.fallbackVolumeId = fallbackId
                override.action = .useDefaultFallback
            }
            if let setDefault = action.setAsDefault, setDefault {
                override.action = .useDefaultFallback
            }
            if let migrate = action.migrateOnReconnect {
                override.migrateOnReconnect = migrate
            }
            if let secondary = action.makeSecondary {
                override.isSecondary = secondary
            }
            if let syncModeRaw = action.syncMode,
               let syncMode = FallbackPolicy.SecondarySyncMode(rawValue: syncModeRaw) {
                override.secondarySyncMode = syncMode
            }

            policy.volumeOverrides[volId] = override
        }

        try? policy.save()

        // Acknowledge save to web view.
        webView.evaluateJavaScript("window.lfgSaveAck && window.lfgSaveAck()") { _, _ in }
    }

    // MARK: - Close

    override func close() {
        Self.instance = nil
        super.close()
    }

    // MARK: - Codable action payload from JS

    private struct FallbackAction: Decodable {
        let type: String
        let volumeIds: [String]?
        let fallbackVolumeId: String?
        let hostName: String?
        let setAsDefault: Bool?
        let migrateOnReconnect: Bool?
        let makeSecondary: Bool?
        let syncMode: String?
    }

    // MARK: - Inline fallback HTML

    private func inlineFallbackHTML(availableVolumes: [(id: String, purpose: String, mounted: Bool)]) -> String {
        let volOptions = availableVolumes.map { v in
            let label = "\(v.id) — \(v.purpose)\(v.mounted ? " ✓" : "")"
            return "<option value=\"\(v.id)\">\(label)</option>"
        }.joined(separator: "\n")

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
        *{box-sizing:border-box}
        body{margin:0;background:#111;color:#e5e7eb;font-family:system-ui;padding:24px;font-size:13px}
        h2{font-size:16px;font-weight:600;margin:0 0 4px}
        p.sub{color:#9ca3af;margin:0 0 20px;font-size:12px}
        label{display:block;margin-bottom:6px;color:#d1d5db}
        select,input{width:100%;padding:7px 10px;background:#1f2937;border:1px solid #374151;color:#e5e7eb;border-radius:6px;font-size:13px;margin-bottom:14px}
        .row{display:flex;align-items:center;gap:8px;margin-bottom:10px}
        .row input[type=checkbox]{width:auto;margin:0}
        .section{background:#1a1f2e;border:1px solid #2d3748;border-radius:8px;padding:16px;margin-bottom:14px}
        .section h3{font-size:13px;font-weight:600;color:#a5b4fc;margin:0 0 12px}
        .actions{display:flex;gap:8px;justify-content:flex-end;margin-top:8px}
        button{padding:7px 16px;border:1px solid #374151;border-radius:6px;cursor:pointer;font-size:13px}
        .btn-primary{background:#4f46e5;border-color:#4f46e5;color:#fff}
        .btn-secondary{background:#1f2937;color:#e5e7eb}
        .sync-opts{margin-top:8px;display:none}
        .sync-opts.visible{display:block}
        .badge{display:inline-block;padding:2px 6px;border-radius:4px;font-size:11px;background:#064e3b;color:#34d399;margin-left:4px}
        </style></head>
        <body>
        <h2>DevDrive — Fallback Volume</h2>
        <p class="sub">Configure what LFG uses when required volumes are unavailable</p>

        <div class="section">
          <h3>Fallback Volume</h3>
          <label>Use this volume instead:</label>
          <select id="fallbackVol">
            <option value="">— on-disk fallback directory (default) —</option>
            \(volOptions)
          </select>
          <div class="row">
            <input type="checkbox" id="setDefault">
            <label style="margin:0">Set as default for all unavailable volumes</label>
          </div>
          <div class="row" id="migrateRow" style="display:none">
            <input type="checkbox" id="migrateOnReconnect">
            <label style="margin:0">Migrate data to this volume once original drive reconnects</label>
          </div>
        </div>

        <div class="section">
          <h3>Secondary DevDrive <span class="badge">Optional</span></h3>
          <div class="row">
            <input type="checkbox" id="makeSecondary" onchange="document.getElementById('syncOpts').classList.toggle('visible',this.checked)">
            <label style="margin:0">Make selected volume a secondary devdrive</label>
          </div>
          <div class="sync-opts" id="syncOpts">
            <label>When both volumes are available:</label>
            <select id="syncMode">
              <option value="syncToPrimary">Sync to primary (secondary is read replica)</option>
              <option value="combineContents">Combine contents into single namespace</option>
            </select>
          </div>
        </div>

        <div class="actions">
          <button class="btn-secondary" onclick="dismiss()">Cancel</button>
          <button class="btn-primary" onclick="save()">Save</button>
        </div>

        <script>
        document.getElementById('fallbackVol').addEventListener('change', function() {
          document.getElementById('migrateRow').style.display = this.value ? 'flex' : 'none';
        });

        function buildPayload(type) {
          return {
            type,
            fallbackVolumeId: document.getElementById('fallbackVol').value || null,
            setAsDefault: document.getElementById('setDefault').checked,
            migrateOnReconnect: document.getElementById('migrateOnReconnect').checked,
            makeSecondary: document.getElementById('makeSecondary').checked,
            syncMode: document.getElementById('syncMode').value
          };
        }

        function save() {
          webkit.messageHandlers.lfgFallback.postMessage(JSON.stringify(buildPayload('save')));
        }
        function dismiss() {
          webkit.messageHandlers.lfgFallback.postMessage(JSON.stringify({type:'dismiss'}));
        }
        window.lfgSaveAck = function() {
          document.querySelector('.btn-primary').textContent = 'Saved ✓';
          setTimeout(() => { window.webkit && webkit.messageHandlers.lfgFallback.postMessage(JSON.stringify({type:'dismiss'})); }, 800);
        };
        </script>
        </body></html>
        """
    }
}

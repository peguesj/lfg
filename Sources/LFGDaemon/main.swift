import Foundation
import LFGKit

// MARK: - APM notify (fire-and-forget)

func apmNotify(event: String, detail: String = "") {
    Task {
        guard let url = URL(string: "http://localhost:3032/api/notify") else { return }
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "project": "lfg",
            "event": event,
            "detail": detail,
            "source": "LFGDaemon"
        ])
        _ = try? await URLSession.shared.data(for: req)
    }
}

// MARK: - Entry point

/// LFGDaemon — persistent XPC service for volume mount/unmount orchestration.
///
/// Boot sequence:
/// 1. Load fleet.json
/// 2. Start MountOrchestrator
/// 3. Start VolumeEventWatcher (FSEvents on /Volumes)
/// 4. Start XPC listener (DaemonXPCService)
/// 5. RunLoop.main.run() — never returns

let fleetURL: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("DevDrive/fleet.json")
}()

guard let registry = try? FleetRegistry(url: fleetURL) else {
    LFGLogger.info("Fatal: could not load fleet.json at \(fleetURL.path)")
    exit(1)
}

let orchestrator = MountOrchestrator(registry: registry)
let xpcService = DaemonXPCService(orchestrator: orchestrator, registry: registry)

// Track manual-eject flag: suppress auto-mount once after user pauses.
var autoMountPaused = false

NotificationCenter.default.addObserver(
    forName: .lfgPauseAutoMount,
    object: nil,
    queue: .main
) { _ in
    autoMountPaused = true
    LFGLogger.info("Auto-mount paused by user request.")
}

let watcher = VolumeEventWatcher(debounceInterval: 0.5, callbackQueue: .main)

watcher.onEvent = { event in
    switch event {
    case .appeared(let name):
        guard registry.isKnownHost(name) else { return }
        if autoMountPaused {
            LFGLogger.info("Host \(name) appeared but auto-mount is paused — skipping attach.")
            autoMountPaused = false
            return
        }
        LFGLogger.info("Host \(name) appeared — attaching sparseimages.")
        Task {
            let results = await orchestrator.attachAll(forHost: name)
            for r in results { LFGLogger.info(r.message) }
            apmNotify(event: "host_appeared", detail: name)
        }

    case .disappeared(let name):
        guard registry.isKnownHost(name) else { return }
        LFGLogger.info("Host \(name) disappeared — detaching sparseimages.")
        Task {
            let results = await orchestrator.detachAll(forHost: name)
            for r in results { LFGLogger.info(r.message) }
            apmNotify(event: "host_disappeared", detail: name)
        }
    }
}

watcher.start()
xpcService.start()

apmNotify(event: "daemon_started")
LFGLogger.info(
    "LFGDaemon started. Watching /Volumes for: \(registry.allHosts.sorted().joined(separator: ", "))"
)

RunLoop.main.run()

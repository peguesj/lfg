import AppKit
import Foundation
import Observation
import UserNotifications
import LFGKit

@Observable
@MainActor
final class AppState {
    let fleet = FleetMonitorService()
    var moduleStatuses: [LFGModule: ModuleStatus] = {
        var map: [LFGModule: ModuleStatus] = [:]
        for module in LFGModule.allCases {
            map[module] = ModuleStatus()
        }
        return map
    }()

    var selectedModule: LFGModule? = nil
    var totalDiskSpace: UInt64 = 0
    var freeDiskSpace: UInt64 = 0

    // MARK: - Mount orchestration (CP-111)

    /// Retained to keep the orchestrator alive between notifications.
    var orchestrator: MountOrchestrator?

    /// NSWorkspace notification observer token — removed on deinit.
    /// `nonisolated(unsafe)` allows deinit (which is nonisolated) to read this
    /// without a concurrency error; the value is only written once on the main
    /// actor during `setupMountWatcher()`.
    nonisolated(unsafe) private var mountObserverToken: (any NSObjectProtocol)?

    deinit {
        if let token = mountObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    // MARK: - Computed disk properties

    var usedDiskSpace: UInt64 {
        totalDiskSpace > freeDiskSpace ? totalDiskSpace - freeDiskSpace : 0
    }

    var diskUsagePercent: Double {
        guard totalDiskSpace > 0 else { return 0 }
        return Double(usedDiskSpace) / Double(totalDiskSpace) * 100.0
    }

    // MARK: - Disk info

    func updateDiskInfo() {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        ) else { return }
        totalDiskSpace = (attrs[.systemSize] as? UInt64) ?? 0
        freeDiskSpace = (attrs[.systemFreeSize] as? UInt64) ?? 0
    }

    // MARK: - Mount watcher setup (CP-111)

    /// Loads the fleet registry, creates the MountOrchestrator, and subscribes to
    /// `NSWorkspace.didMountNotification`. Safe to call multiple times — returns early
    /// if the orchestrator is already initialised.
    func setupMountWatcher() {
        guard orchestrator == nil else { return }

        let fleetURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("DevDrive/fleet.json")

        let registry: FleetRegistry
        do {
            registry = try FleetRegistry(url: fleetURL)
        } catch {
            // fleet.json missing or malformed — mount watcher cannot start.
            sendNotification(
                title: "LFG — Mount Watcher",
                body: "Could not load fleet.json: \(error.localizedDescription)",
                identifier: "lfg.mountwatcher.fleet-load-error"
            )
            return
        }

        let newOrchestrator = MountOrchestrator(registry: registry)
        orchestrator = newOrchestrator

        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let volumeName = notification.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String
            else { return }

            // Only act on hosts known to the fleet registry.
            guard registry.isKnownHost(volumeName) else { return }

            Task {
                let results = await newOrchestrator.attachAll(forHost: volumeName)
                await MainActor.run {
                    self.handleAttachResults(results, host: volumeName)
                }
            }
        }
        mountObserverToken = token
    }

    // MARK: - Attach result handling (CP-111)

    private func handleAttachResults(_ results: [AttachResult], host: String) {
        let succeeded = results.filter(\.succeeded)
        let failed = results.filter { !$0.succeeded }

        // TODO: CP-115 — restore missing OffloadRule symlinks for each succeeded drive.
        // When LFGKit.OffloadRule and VolumeBackend.offloadRules are available:
        //   for result in succeeded {
        //       if let drive = registry.drive(id: result.id) {
        //           for rule in drive.offloadRules { rule.restoreSymlinkIfNeeded() }
        //       }
        //   }

        let notifBody: String
        if failed.isEmpty {
            notifBody = "\(host) mounted — attached \(succeeded.count) volume(s): \(succeeded.map(\.id).joined(separator: ", "))"
        } else {
            let failList = failed.map { "\($0.id): \($0.message)" }.joined(separator: "; ")
            notifBody = "\(host) mounted — \(succeeded.count) ok, \(failed.count) failed (\(failList))"
        }

        sendNotification(
            title: "LFG — DevDrive",
            body: notifBody,
            identifier: "lfg.devdrive.attach.\(host)"
        )
    }

    // MARK: - Notification helper (CP-110)

    /// Sends a local UNUserNotification. Fire-and-forget; errors are silently dropped.
    func sendNotification(
        title: String,
        body: String,
        identifier: String = UUID().uuidString
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil          // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

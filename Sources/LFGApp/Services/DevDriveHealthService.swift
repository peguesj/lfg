import AppKit
import Foundation
import Observation
import UserNotifications
import LFGKit

// MARK: - DevDriveHealthService

/// Periodically scans devdrive health and emits actionable macOS notifications
/// when volumes are unavailable or symlinks are dangling.
///
/// The service fires at app launch and then every `scanInterval` seconds.
/// Notifications are rate-limited per-volume using a cooldown window to avoid
/// alert fatigue — a single volume won't trigger more than one notification
/// per `alertCooldown`.
@Observable
@MainActor
public final class DevDriveHealthService {

    // MARK: Published state

    public private(set) var lastReport: SymlinkHealthReport?
    public private(set) var isScanning = false

    // MARK: Configuration

    /// How often to run a background health scan (seconds).
    public var scanInterval: TimeInterval = 120

    /// Minimum seconds between repeated alerts for the same volume.
    public var alertCooldown: TimeInterval = 1800   // 30 min

    // MARK: Private

    private var timer: Timer?
    private var lastAlertTimes: [String: Date] = [:]

    private let fleetURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("DevDrive/fleet.json")

    // MARK: Lifecycle

    public init() {}

    /// Start the periodic scan loop. Idempotent.
    public func start() {
        guard timer == nil else { return }
        Task { await scan() }
        timer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.scan() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Scan

    @discardableResult
    public func scan() async -> SymlinkHealthReport? {
        guard !isScanning else { return lastReport }
        isScanning = true
        defer { isScanning = false }

        let report = await Task.detached(priority: .background) { [fleetURL] in
            guard let registry = try? FleetRegistry(url: fleetURL) else { return SymlinkHealthReport(
                danglingRules: [],
                missingHostVolumes: [],
                scannedAt: Date()
            )}
            return SymlinkHealthScanner(registry: registry).scan()
        }.value

        lastReport = report
        await fireAlertsIfNeeded(for: report)
        return report
    }

    // MARK: - Alert dispatch

    private func fireAlertsIfNeeded(for report: SymlinkHealthReport) async {
        guard !report.isHealthy else { return }

        // Group missing volumes by external host so we send one notification per host.
        var hostGroups: [String: [SymlinkHealthReport.MissingHostVolume]] = [:]
        for vol in report.missingHostVolumes {
            hostGroups[vol.hostName, default: []].append(vol)
        }

        for (host, volumes) in hostGroups {
            let cooldownKey = "host.\(host)"
            if let last = lastAlertTimes[cooldownKey],
               Date().timeIntervalSince(last) < alertCooldown { continue }

            lastAlertTimes[cooldownKey] = Date()

            let volumeList = volumes.map(\.volumeId).joined(separator: ", ")
            let body = "\(volumes.count) volume(s) need \(host): \(volumeList)"

            DevDriveNotificationCategories.sendUnavailableAlert(
                title: "DevDrive volumes unavailable",
                body: body,
                hostName: host,
                volumeIds: volumes.map(\.volumeId)
            )
        }

        // Alert for dangling rules on volumes that ARE mounted (host is connected but symlink broke).
        let mountedDangling = report.danglingRules.filter { $0.volumeMounted }
        if !mountedDangling.isEmpty {
            let uniqueVols = Set(mountedDangling.map(\.volumeId))
            let cooldownKey = "dangling.\(uniqueVols.sorted().joined(separator: "-"))"
            if let last = lastAlertTimes[cooldownKey],
               Date().timeIntervalSince(last) < alertCooldown { return }
            lastAlertTimes[cooldownKey] = Date()

            let content = UNMutableNotificationContent()
            content.title = "LFG — Broken symlinks"
            content.body = "\(mountedDangling.count) offload symlink(s) are dangling. Open LFG to restore."
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "lfg.devdrive.dangling", content: content, trigger: nil)
            )
        }
    }
}

import Foundation
import AppKit
import Observation
import LFGKit

// MARK: - Live volume model

/// A single fleet volume with live mount + capacity state.
public struct LiveVolumeRow: Identifiable, Sendable, Equatable {
    public let id: String          // fleet.json drive id
    public let imagePath: String   // resolved sparseimage path
    public let mountPath: String   // expected mount point
    public let host: String
    public let tier: String        // "hot" | "warm" | "cold" | "always_internal"
    public var isMounted: Bool
    public var freeBytes: Int64
    public var totalBytes: Int64

    public var freeFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(freeBytes) / Double(totalBytes)
    }

    public var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
}

// MARK: - FleetMonitorService

/// @Observable service that owns fleet.json parsing and live volume mount state.
///
/// Auto-refreshes on:
/// - `NSWorkspace.didMountNotification` / `didUnmountNotification`
/// - A 5-second polling timer (covers cases where the daemon attaches without a
///   Workspace notification, e.g. hdiutil called from shell)
///
/// Both the menubar and the main window share one instance via `AppState`.
@Observable
@MainActor
public final class FleetMonitorService {

    // MARK: Published state

    public private(set) var volumes: [LiveVolumeRow] = []
    public private(set) var lastRefreshed: Date? = nil
    public private(set) var isRefreshing = false

    // MARK: Private

    private var timer: Timer?
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    private let fleetURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("DevDrive/fleet.json")

    private let refreshInterval: TimeInterval = 5

    // MARK: Lifecycle

    public init() {}

    public func start() {
        refresh()
        scheduleTimer()
        observeWorkspace()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let obs = mountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            mountObserver = nil
        }
        if let obs = unmountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            unmountObserver = nil
        }
    }

    /// Trigger an immediate refresh (e.g. after a user action).
    public func refresh() {
        Task { @MainActor in
            await doRefresh()
        }
    }

    // MARK: Private helpers

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.doRefresh()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.doRefresh() }
        }
        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.doRefresh() }
        }
    }

    @MainActor
    private func doRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let registry = try? FleetRegistry(url: fleetURL) else { return }

        // Snapshot current /Volumes in one shot (cheap, filesystem-level check)
        let liveVolumePaths: Set<String> = {
            let url = URL(fileURLWithPath: "/Volumes")
            let items = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )) ?? []
            return Set(items.map { "/Volumes/" + $0.lastPathComponent })
        }()

        // Read tier from fleet.json via raw JSON (FleetRegistry doesn't expose it)
        let rawTiers: [String: String] = loadRawTiers()

        var rows: [LiveVolumeRow] = []
        for drive in registry.allDrives.sorted(by: { $0.id < $1.id }) {
            // Skip the archival/on-demand placeholder
            guard !drive.id.hasPrefix("btau") else { continue }

            let mounted = liveVolumePaths.contains(drive.mount) ||
                          checkMountAlias(for: drive.id, liveVolumePaths: liveVolumePaths)

            var freeBytes: Int64 = 0
            var totalBytes: Int64 = 0

            if mounted {
                let mountPoint = resolveActiveMountPath(drive: drive, liveVolumePaths: liveVolumePaths)
                if let stats = volumeStats(at: mountPoint) {
                    freeBytes = stats.free
                    totalBytes = stats.total
                }
            }

            rows.append(LiveVolumeRow(
                id: drive.id,
                imagePath: drive.resolvedImagePath,
                mountPath: drive.mount,
                host: drive.host,
                tier: rawTiers[drive.id] ?? "unknown",
                isMounted: mounted,
                freeBytes: freeBytes,
                totalBytes: totalBytes
            ))
        }

        volumes = rows
        lastRefreshed = .now
    }

    // Fleet.json has a "tier" field not in FleetRegistry — parse it raw.
    private func loadRawTiers() -> [String: String] {
        guard let data = try? Data(contentsOf: fleetURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let drives = json["drives"] as? [[String: Any]] else { return [:] }
        var map: [String: String] = [:]
        for d in drives {
            if let id = d["id"] as? String, let tier = d["tier"] as? String {
                map[id] = tier
            }
        }
        return map
    }

    // Some volumes use a mount_alias (e.g. 902APMDR mounts at /Volumes/DDRV902).
    // Encode the known aliases here until FleetRegistry exposes them.
    private func checkMountAlias(for id: String, liveVolumePaths: Set<String>) -> Bool {
        let aliases: [String: String] = [
            "902APMDR": "/Volumes/DDRV902",
            "903CLAUD": "/Volumes/903LUME",
            "904MEMVT": "/Volumes/DDRV-904-MEMVT-v2",
        ]
        if let alias = aliases[id] {
            return liveVolumePaths.contains(alias)
        }
        return false
    }

    private func resolveActiveMountPath(drive: FleetDrive, liveVolumePaths: Set<String>) -> String {
        if liveVolumePaths.contains(drive.mount) { return drive.mount }
        let aliases: [String: String] = [
            "902APMDR": "/Volumes/DDRV902",
            "903CLAUD": "/Volumes/903LUME",
            "904MEMVT": "/Volumes/DDRV-904-MEMVT-v2",
        ]
        return aliases[drive.id] ?? drive.mount
    }

    private func volumeStats(at path: String) -> (total: Int64, free: Int64)? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(0)
        return (Int64(total), free)
    }
}

import Foundation

// MARK: - Raw fleet.json decodable models

/// Represents one entry from the `drives` array in fleet.json.
public struct FleetDrive: Codable, Sendable, Equatable {
    public let id: String
    /// Path to the sparseimage / sparsebundle file (may start with ~ or $HOME).
    public let image: String
    /// Expected APFS mount point after `hdiutil attach`.
    public let mount: String
    public let host: String
    /// Reconnect policy: "auto" | "manual" | "none".
    public let reconnect_policy: String?

    public init(id: String, image: String, mount: String, host: String, reconnect_policy: String?) {
        self.id = id
        self.image = image
        self.mount = mount
        self.host = host
        self.reconnect_policy = reconnect_policy
    }

    /// Whether this drive should be auto-attached when its host appears.
    public var isAutoReconnect: Bool {
        reconnect_policy == "auto"
    }

    /// Returns the absolute image path with `~` expanded to the current user's home directory.
    public var resolvedImagePath: String {
        if image.hasPrefix("~/") {
            return (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                .appendingPathComponent(String(image.dropFirst(2)))
        } else if image.hasPrefix("$HOME/") {
            return (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                .appendingPathComponent(String(image.dropFirst(6)))
        }
        return image
    }
}

// MARK: - Fleet registry

/// Parses and indexes `fleet.json`, providing host-based lookups for the daemon.
///
/// Usage:
/// ```swift
/// let registry = try FleetRegistry(url: URL(fileURLWithPath: "/Users/jeremiah/DevDrive/fleet.json"))
/// let drives = registry.drives(forHost: "YJ_MORE")
/// ```
public final class FleetRegistry: @unchecked Sendable {

    // MARK: Private state

    private var drivesByHost: [String: [FleetDrive]] = [:]
    private var drivesById: [String: FleetDrive] = [:]

    // MARK: Nested raw model

    private struct RawFleet: Codable {
        let drives: [FleetDriveCodable]
    }

    private struct FleetDriveCodable: Codable {
        let id: String?
        let image: String?
        let mount: String?
        let host: String?
        let reconnect_policy: String?
    }

    // MARK: Initialisation

    /// Load from an explicit URL (enables test injection).
    public init(url: URL) throws {
        let data = try Data(contentsOf: url)
        try load(from: data)
    }

    /// Load from raw JSON data (test use).
    public init(jsonData: Data) throws {
        try load(from: jsonData)
    }

    private func load(from data: Data) throws {
        let raw = try JSONDecoder().decode(RawFleet.self, from: data)
        for entry in raw.drives {
            guard
                let id = entry.id, !id.isEmpty,
                let image = entry.image, !image.isEmpty,
                let mount = entry.mount, !mount.isEmpty,
                let host = entry.host, !host.isEmpty
            else { continue }

            let drive = FleetDrive(
                id: id,
                image: image,
                mount: mount,
                host: host,
                reconnect_policy: entry.reconnect_policy
            )
            drivesById[id] = drive
            drivesByHost[host, default: []].append(drive)
        }
    }

    // MARK: Public API

    /// All drives whose `host` field matches the given volume name (e.g. "YJ_MORE").
    public func drives(forHost host: String) -> [FleetDrive] {
        drivesByHost[host] ?? []
    }

    /// All drives with `reconnect_policy == "auto"` for a given host.
    public func autoDrives(forHost host: String) -> [FleetDrive] {
        drives(forHost: host).filter(\.isAutoReconnect)
    }

    /// Look up a single drive by its id (e.g. "901DEVLIB").
    public func drive(id: String) -> FleetDrive? {
        drivesById[id]
    }

    /// All registered drives.
    public var allDrives: [FleetDrive] {
        Array(drivesById.values)
    }

    /// All unique host names in the registry.
    public var allHosts: Set<String> {
        Set(drivesByHost.keys)
    }

    /// Whether `host` is a known external host.
    public func isKnownHost(_ host: String) -> Bool {
        drivesByHost[host] != nil
    }
}

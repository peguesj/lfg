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
/// The registry exposes two parallel APIs:
/// - **v2 API** (`FleetDrive`-based): used by `MountOrchestrator` — preserved unchanged.
/// - **v3 API** (`SourceVolume` / `VolumeBackend`-based): richer three-tier model
///   that also exposes `OffloadRule` values parsed from the `symlinks` arrays.
///
/// Usage (v2):
/// ```swift
/// let registry = try FleetRegistry(url: URL(fileURLWithPath: "/Users/jeremiah/DevDrive/fleet.json"))
/// let drives = registry.drives(forHost: "YJ_MORE")
/// ```
///
/// Usage (v3):
/// ```swift
/// let registry = try FleetRegistry(url: fleetURL)
/// let host = registry.sourceVolume(named: "YJ_MORE")
/// let backends = registry.volumeBackends(forHost: "YJ_MORE")
/// let autoBackends = registry.autoBackends(forHost: "YJ_MORE")
/// ```
public final class FleetRegistry: @unchecked Sendable {

    // MARK: Private state — v2

    private var drivesByHost: [String: [FleetDrive]] = [:]
    private var drivesById: [String: FleetDrive] = [:]

    // MARK: Private state — v3

    private var sourceVolumesByName: [String: SourceVolume] = [:]
    private var backendsByHost: [String: [VolumeBackend]] = [:]
    private var backendsById: [String: VolumeBackend] = [:]

    // MARK: Nested raw models

    private struct RawFleet: Codable {
        let drives: [FleetDriveCodable]
        let externalHosts: [SourceVolume]?

        private enum CodingKeys: String, CodingKey {
            case drives
            case externalHosts = "external_hosts"
        }
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

        // v2: parse drives into FleetDrive index
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

        // v3: index SourceVolumes
        for host in raw.externalHosts ?? [] {
            sourceVolumesByName[host.name] = host
        }

        // v3: parse drives into VolumeBackend index (best-effort — skip malformed entries)
        let v3Decoder = JSONDecoder()
        if let drivesArray = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawDrives = drivesArray["drives"] as? [[String: Any]] {
            for driveDict in rawDrives {
                guard let driveData = try? JSONSerialization.data(withJSONObject: driveDict),
                      let backend = try? v3Decoder.decode(VolumeBackend.self, from: driveData)
                else { continue }
                backendsById[backend.id] = backend
                backendsByHost[backend.host, default: []].append(backend)
            }
        }
    }

    // MARK: Public API — v2 (unchanged, MountOrchestrator dependency)

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

    // MARK: Public API — v3

    /// All `SourceVolume` entries parsed from `external_hosts[]` in fleet.json.
    public var allSourceVolumes: [SourceVolume] {
        Array(sourceVolumesByName.values)
    }

    /// All `VolumeBackend` entries parsed from `drives[]` in fleet.json.
    public var allVolumeBackends: [VolumeBackend] {
        Array(backendsById.values)
    }

    /// All `VolumeBackend` entries whose `host` matches the given source volume name.
    ///
    /// - Parameter host: The `SourceVolume.name` to filter by (e.g. `"YJ_MORE"`).
    public func volumeBackends(forHost host: String) -> [VolumeBackend] {
        backendsByHost[host] ?? []
    }

    /// Look up a `SourceVolume` by its `name` field (e.g. `"YJ_MORE"`).
    public func sourceVolume(named name: String) -> SourceVolume? {
        sourceVolumesByName[name]
    }

    /// All `VolumeBackend` entries for a given host whose `reconnect_policy` is `"auto"`.
    ///
    /// - Parameter host: The `SourceVolume.name` to filter by.
    public func autoBackends(forHost host: String) -> [VolumeBackend] {
        volumeBackends(forHost: host).filter(\.isAutoReconnect)
    }
}

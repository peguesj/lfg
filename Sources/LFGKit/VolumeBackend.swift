import Foundation

// MARK: - VolumeBackend

/// Represents one entry from the `drives[]` array in fleet.json — a sparseimage-backed APFS volume.
///
/// `VolumeBackend` is the v3 enriched counterpart to `FleetDrive`. It carries all of the
/// same raw JSON fields plus:
/// - `offloadRules`: parsed `OffloadRule` values derived from the raw `symlinks` strings.
/// - `isAutoReconnect`: convenience flag computed from `reconnectPolicy`.
/// - `resolvedImagePath`: `~/` and `$HOME/` expanded to an absolute path.
///
/// `FleetDrive` and its associated v2 API remain unchanged for backward compatibility.
///
/// Example fleet.json entry:
/// ```json
/// {
///   "id": "901DEVLIB",
///   "image": "/Volumes/YJ_MORE/DevDrive/901DEVLIB.dmg.sparseimage",
///   "mount": "/Volumes/DDRV-901-DEVLIB",
///   "host": "YJ_MORE",
///   "tier": "cold",
///   "purpose": "Xcode DerivedData + CoreSimulator + home dir offloads",
///   "reconnect_policy": "auto",
///   "symlinks": [
///     "~/.npm-cache → /Volumes/DDRV-901-DEVLIB/npm-cache"
///   ]
/// }
/// ```
///
/// Usage:
/// ```swift
/// let registry = try FleetRegistry(url: fleetURL)
/// let backends = registry.allVolumeBackends
/// for rule in backends.first?.offloadRules ?? [] {
///     print(rule.source, "→", rule.target, "healthy:", rule.isHealthy)
/// }
/// ```
public struct VolumeBackend: Codable, Sendable, Equatable {

    // MARK: Stored properties (direct from JSON)

    /// Unique identifier for this volume (e.g. `"901DEVLIB"`).
    public let id: String

    /// Path to the `.sparseimage` or `.sparsebundle` file. May start with `~/` or `$HOME/`.
    public let image: String

    /// Expected APFS mount point after `hdiutil attach` (e.g. `"/Volumes/DDRV-901-DEVLIB"`).
    public let mount: String

    /// Foreign-key reference to the `SourceVolume.name` that hosts this image
    /// (e.g. `"YJ_MORE"`, or `"internal"` for internal-disk volumes).
    public let host: String

    /// Storage tier classification. Expected values: `"cold"`, `"hot"`, `"warm"`,
    /// `"always_internal"`, `"archival"`. `nil` if omitted.
    public let tier: String?

    /// Human-readable description of the volume's purpose. `nil` if omitted.
    public let purpose: String?

    /// Reconnect policy string from fleet.json. Expected values: `"auto"`, `"manual"`, `"none"`.
    /// `nil` if omitted (treated as manual / no auto-reconnect).
    public let reconnectPolicy: String?

    /// Raw symlink strings as stored in fleet.json before parsing.
    ///
    /// Example: `["~/.npm-cache → /Volumes/DDRV-901-DEVLIB/npm-cache"]`
    public let rawSymlinks: [String]

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id
        case image
        case mount
        case host
        case tier
        case purpose
        case reconnectPolicy    = "reconnect_policy"
        case rawSymlinks        = "symlinks"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(String.self, forKey: .id)
        image           = try c.decode(String.self, forKey: .image)
        mount           = try c.decode(String.self, forKey: .mount)
        host            = try c.decode(String.self, forKey: .host)
        tier            = try c.decodeIfPresent(String.self, forKey: .tier)
        purpose         = try c.decodeIfPresent(String.self, forKey: .purpose)
        reconnectPolicy = try c.decodeIfPresent(String.self, forKey: .reconnectPolicy)
        rawSymlinks     = try c.decodeIfPresent([String].self, forKey: .rawSymlinks) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,    forKey: .id)
        try c.encode(image, forKey: .image)
        try c.encode(mount, forKey: .mount)
        try c.encode(host,  forKey: .host)
        try c.encodeIfPresent(tier,            forKey: .tier)
        try c.encodeIfPresent(purpose,         forKey: .purpose)
        try c.encodeIfPresent(reconnectPolicy, forKey: .reconnectPolicy)
        try c.encode(rawSymlinks,              forKey: .rawSymlinks)
    }

    // MARK: Derived properties

    /// Parsed `OffloadRule` values derived from `rawSymlinks`.
    ///
    /// Entries that cannot be parsed (malformed arrow strings) are silently dropped.
    public var offloadRules: [OffloadRule] {
        rawSymlinks.compactMap { OffloadRule(raw: $0) }
    }

    /// Whether this volume should be auto-attached when its host volume mounts.
    public var isAutoReconnect: Bool {
        reconnectPolicy == "auto"
    }

    /// Absolute path to the sparseimage, with `~` and `$HOME` expanded to the
    /// current user's home directory.
    ///
    /// Mirrors the expansion logic in `FleetDrive.resolvedImagePath`.
    public var resolvedImagePath: String {
        if image.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return (home as NSString).appendingPathComponent(String(image.dropFirst(2)))
        } else if image.hasPrefix("$HOME/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return (home as NSString).appendingPathComponent(String(image.dropFirst(6)))
        }
        return image
    }
}

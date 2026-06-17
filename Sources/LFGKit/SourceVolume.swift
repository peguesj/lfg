import Foundation

// MARK: - SourceVolume

/// Represents one entry from the `external_hosts` array in fleet.json.
///
/// A `SourceVolume` is the physical host volume — typically an external drive — that
/// holds one or more sparseimage-backed APFS volumes (`VolumeBackend`).
///
/// Example fleet.json entry:
/// ```json
/// {
///   "name": "YJ_MORE",
///   "mount": "/Volumes/YJ_MORE",
///   "role": "external_host",
///   "available_gb": 179,
///   "status": "active",
///   "keep_awake": true
/// }
/// ```
///
/// Usage:
/// ```swift
/// let registry = try FleetRegistry(url: fleetURL)
/// if let host = registry.sourceVolume(named: "YJ_MORE") {
///     print(host.mount)  // "/Volumes/YJ_MORE"
///     print(host.keepAwake)  // true
/// }
/// ```
public struct SourceVolume: Codable, Sendable, Equatable {

    // MARK: Properties

    /// The unique identifier / display name of the external host (e.g. "YJ_MORE").
    public let name: String

    /// The expected mount point for this physical volume (e.g. "/Volumes/YJ_MORE").
    public let mount: String

    /// The functional role of this volume. Expected value: `"external_host"`.
    public let role: String

    /// Free space on this host in gigabytes, as last recorded in fleet.json.
    /// May be `nil` if not recorded.
    public let availableGB: Int?

    /// Operational status string (e.g. `"active"`, `"available"`).
    /// `nil` if omitted from fleet.json.
    public let status: String?

    /// When `true`, an OS keep-awake mechanism should be engaged to prevent
    /// the external drive from spinning down unexpectedly.
    public let keepAwake: Bool

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case name
        case mount
        case role
        case availableGB    = "available_gb"
        case status
        case keepAwake      = "keep_awake"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name        = try c.decode(String.self, forKey: .name)
        mount       = try c.decode(String.self, forKey: .mount)
        role        = try c.decode(String.self, forKey: .role)
        availableGB = try c.decodeIfPresent(Int.self, forKey: .availableGB)
        status      = try c.decodeIfPresent(String.self, forKey: .status)
        keepAwake   = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name,        forKey: .name)
        try c.encode(mount,       forKey: .mount)
        try c.encode(role,        forKey: .role)
        try c.encodeIfPresent(availableGB, forKey: .availableGB)
        try c.encodeIfPresent(status,      forKey: .status)
        try c.encode(keepAwake,   forKey: .keepAwake)
    }

    // MARK: Computed helpers

    /// Whether this host volume is currently mounted at its expected mount point.
    public var isMounted: Bool {
        FileManager.default.fileExists(atPath: mount)
    }
}

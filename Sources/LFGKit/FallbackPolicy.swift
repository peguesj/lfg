import Foundation

// MARK: - FallbackPolicy

/// Persisted user preferences for how LFG handles unavailable devdrive volumes.
///
/// Stored under `fallback_policy:` in `~/.config/lfg/settings.yaml`.
/// The Swift layer reads/writes the single JSON representation at
/// `~/.config/lfg/fallback_policy.json` (sidecar file, avoids YAML mutation).
public struct FallbackPolicy: Codable, Sendable, Equatable {

    // MARK: Volume-level override

    /// Per-volume overrides keyed by volume id (e.g. `"901DEVLIB"`).
    public var volumeOverrides: [String: VolumeOverride]

    // MARK: Global defaults

    /// Default action taken when a required volume is unavailable.
    public var defaultAction: UnavailableAction

    /// When `true`, silently apply the default action without prompting.
    public var suppressPrompt: Bool

    // MARK: Init

    public init(
        volumeOverrides: [String: VolumeOverride] = [:],
        defaultAction: UnavailableAction = .prompt,
        suppressPrompt: Bool = false
    ) {
        self.volumeOverrides = volumeOverrides
        self.defaultAction = defaultAction
        self.suppressPrompt = suppressPrompt
    }

    // MARK: - UnavailableAction

    public enum UnavailableAction: String, Codable, Sendable, CaseIterable {
        case prompt            // Show notification + UI
        case useDefaultFallback // Write to ~/DevDrive/<id>-fallback/ silently
        case ignore            // No action, no notification
    }

    // MARK: - VolumeOverride

    public struct VolumeOverride: Codable, Sendable, Equatable {
        public var action: UnavailableAction

        /// When set, use this volume id as the fallback instead of the on-disk fallback directory.
        public var fallbackVolumeId: String?

        /// Migrate data to `fallbackVolumeId` once the original host mounts.
        public var migrateOnReconnect: Bool

        /// Treat `fallbackVolumeId` as a secondary devdrive rather than a true fallback.
        public var isSecondary: Bool

        /// When `isSecondary` is true, defines how the two volumes are kept in sync.
        public var secondarySyncMode: SecondarySyncMode

        public init(
            action: UnavailableAction = .prompt,
            fallbackVolumeId: String? = nil,
            migrateOnReconnect: Bool = false,
            isSecondary: Bool = false,
            secondarySyncMode: SecondarySyncMode = .syncToPrimary
        ) {
            self.action = action
            self.fallbackVolumeId = fallbackVolumeId
            self.migrateOnReconnect = migrateOnReconnect
            self.isSecondary = isSecondary
            self.secondarySyncMode = secondarySyncMode
        }
    }

    // MARK: - SecondarySyncMode

    public enum SecondarySyncMode: String, Codable, Sendable, CaseIterable {
        /// rsync primary → secondary (secondary is read replica)
        case syncToPrimary
        /// Merge both volumes into a unified namespace; conflicts prefer primary
        case combineContents
    }

    // MARK: - Persistence

    private static let policyURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/lfg/fallback_policy.json")

    public static func load() -> FallbackPolicy {
        guard let data = try? Data(contentsOf: policyURL),
              let policy = try? JSONDecoder().decode(FallbackPolicy.self, from: data)
        else { return FallbackPolicy() }
        return policy
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: Self.policyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: Self.policyURL, options: .atomic)
    }
}

import Foundation

// MARK: - SymlinkHealthReport

/// Aggregated health snapshot produced by `SymlinkHealthScanner`.
public struct SymlinkHealthReport: Sendable {

    // MARK: Nested types

    /// A single dangling or missing symlink.
    public struct DanglingRule: Sendable {
        /// The volume backend that owns this rule.
        public let volumeId: String
        /// The offload rule that is unhealthy.
        public let rule: OffloadRule
        /// The expected mount point of the volume.
        public let expectedMount: String
        /// Whether the volume is currently mounted (false → mount will heal it).
        public let volumeMounted: Bool
    }

    /// A volume backend whose host (external pool) is not currently connected.
    public struct MissingHostVolume: Sendable {
        public let volumeId: String
        public let expectedMount: String
        public let hostName: String
        /// Absolute path to the sparseimage on the (currently absent) host.
        public let imagePath: String
        /// Whether this volume has any dangling symlinks on the current system.
        public let hasDanglingRules: Bool
    }

    // MARK: Properties

    public let danglingRules: [DanglingRule]
    public let missingHostVolumes: [MissingHostVolume]
    public let scannedAt: Date

    // MARK: Convenience

    public var isHealthy: Bool {
        danglingRules.isEmpty && missingHostVolumes.isEmpty
    }

    /// External host names that are needed but not connected.
    public var missingExternalHosts: Set<String> {
        Set(missingHostVolumes.map(\.hostName).filter { $0 != "internal" })
    }
}

// MARK: - SymlinkHealthScanner

/// Scans the fleet registry to find unhealthy offload rules and volumes
/// whose external host drive is not currently mounted.
public struct SymlinkHealthScanner {

    private let registry: FleetRegistry

    public init(registry: FleetRegistry) {
        self.registry = registry
    }

    public func scan() -> SymlinkHealthReport {
        let fm = FileManager.default
        let now = Date()

        var dangling: [SymlinkHealthReport.DanglingRule] = []
        var missingHosts: [SymlinkHealthReport.MissingHostVolume] = []

        for backend in registry.allVolumeBackends {
            let isMounted = fm.fileExists(atPath: backend.mount)
            let hostMounted: Bool = {
                if backend.host == "internal" { return true }
                // A host is "mounted" when its /Volumes/<name> directory exists.
                return fm.fileExists(atPath: "/Volumes/\(backend.host)")
            }()

            // Record unhealthy offload rules (only meaningful when volume is mounted).
            for rule in backend.offloadRules where !rule.isHealthy {
                dangling.append(SymlinkHealthReport.DanglingRule(
                    volumeId: backend.id,
                    rule: rule,
                    expectedMount: backend.mount,
                    volumeMounted: isMounted
                ))
            }

            // Record volumes whose host isn't connected.
            if !isMounted && !hostMounted && backend.host != "internal" {
                missingHosts.append(SymlinkHealthReport.MissingHostVolume(
                    volumeId: backend.id,
                    expectedMount: backend.mount,
                    hostName: backend.host,
                    imagePath: backend.resolvedImagePath,
                    hasDanglingRules: backend.offloadRules.contains { !$0.isHealthy }
                ))
            }
        }

        return SymlinkHealthReport(
            danglingRules: dangling,
            missingHostVolumes: missingHosts,
            scannedAt: now
        )
    }
}

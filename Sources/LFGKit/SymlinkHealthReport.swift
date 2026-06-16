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
    ///
    /// - Note: Kept for backward compatibility with CP-119/CP-120 callers.
    ///   New consumers should use `UnavailableVolume` (via `unavailableVolumes`)
    ///   which carries a typed `UnavailabilityReason` instead of a single bit.
    public struct MissingHostVolume: Sendable {
        public let volumeId: String
        public let expectedMount: String
        public let hostName: String
        /// Absolute path to the sparseimage on the (currently absent) host.
        public let imagePath: String
        /// Whether this volume has any dangling symlinks on the current system.
        public let hasDanglingRules: Bool
    }

    // MARK: - UnavailableVolume (v3 typed replacement for MissingHostVolume)

    /// Typed unavailability reason for a `VolumeBackend` whose host is mounted but
    /// whose volume is not accessible, or whose fallback is pending reclaim.
    ///
    /// Replaces the single-bit `MissingHostVolume` signal for classifier-aware consumers.
    /// CP-119/CP-120 callers can continue using `missingHostVolumes`; new consumers
    /// should use `unavailableVolumes` for typed diagnosis.
    public struct UnavailableVolume: Sendable {

        public let volumeId: String
        public let expectedMount: String
        public let hostName: String
        public let imagePath: String

        /// Typed reason the volume is unavailable.
        public let reason: UnavailabilityReason

        public enum UnavailabilityReason: Sendable {

            /// Host drive is not connected (e.g. YJ_MORE not plugged in).
            /// Corresponds to the old `MissingHostVolume` single-bit case.
            case hostNotConnected

            /// Host is connected but volume failed to attach; classifier assigned a class.
            ///
            /// - Parameters:
            ///   - class_: The `CorruptionClass` determined from the 3-tuple signature.
            ///   - signature: The raw `CorruptionSignature` for diagnostic surfaces.
            case degraded(class_: CorruptionClass, signature: CorruptionSignature)

            /// Volume is mounted, a fallback directory exists, and the state machine
            /// is `BackendRebuilt` — awaiting the rsync-verify-swap reclaim sequence.
            ///
            /// - Parameters:
            ///   - fallbackSize: Byte count of the fallback directory.
            ///   - holders: Processes currently holding open FDs in the fallback directory.
            ///              Empty → quiescence check will pass.
            case fallbackPendingReclaim(fallbackSize: Int64, holders: [HolderProcess])

            /// `hdiutil attach` returned exit 0 but the expected mount path does not exist.
            /// Treated as a Class A ghost-attach variant (US-A-005).
            case ghostAttach(lastAttemptAt: Date)
        }

        /// Whether this unavailability can be recovered without user intervention.
        public var isAutonomouslyRecoverable: Bool {
            switch reason {
            case .hostNotConnected, .ghostAttach:
                return false
            case .degraded(let cls, _):
                return cls.isAutonomousReclaimable
            case .fallbackPendingReclaim(_, let holders):
                return holders.isEmpty
            }
        }
    }

    // MARK: Properties

    public let danglingRules: [DanglingRule]

    /// Legacy backward-compatible property — preserved for CP-119/CP-120 callers.
    ///
    /// Equivalent to the subset of `unavailableVolumes` whose reason is `.hostNotConnected`.
    public let missingHostVolumes: [MissingHostVolume]

    /// Typed unavailability records. Replaces `missingHostVolumes` for new consumers.
    public let unavailableVolumes: [UnavailableVolume]

    public let scannedAt: Date

    // MARK: Init

    public init(
        danglingRules: [DanglingRule],
        missingHostVolumes: [MissingHostVolume],
        unavailableVolumes: [UnavailableVolume] = [],
        scannedAt: Date
    ) {
        self.danglingRules = danglingRules
        self.missingHostVolumes = missingHostVolumes
        self.unavailableVolumes = unavailableVolumes
        self.scannedAt = scannedAt
    }

    // MARK: Convenience

    public var isHealthy: Bool {
        danglingRules.isEmpty && missingHostVolumes.isEmpty && unavailableVolumes.isEmpty
    }

    /// External host names that are needed but not connected.
    public var missingExternalHosts: Set<String> {
        Set(missingHostVolumes.map(\.hostName).filter { $0 != "internal" })
    }

    /// Volumes with a fallback directory pending the reclaim sequence.
    public var fallbackPendingReclaim: [UnavailableVolume] {
        unavailableVolumes.filter {
            if case .fallbackPendingReclaim = $0.reason { return true }
            return false
        }
    }

    /// Volumes that are degraded with a typed corruption class.
    public var degradedVolumes: [UnavailableVolume] {
        unavailableVolumes.filter {
            if case .degraded = $0.reason { return true }
            return false
        }
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
        var unavailable: [SymlinkHealthReport.UnavailableVolume] = []

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

            if !isMounted && backend.host != "internal" {
                if !hostMounted {
                    // Legacy path: host is not connected at all.
                    missingHosts.append(SymlinkHealthReport.MissingHostVolume(
                        volumeId: backend.id,
                        expectedMount: backend.mount,
                        hostName: backend.host,
                        imagePath: backend.resolvedImagePath,
                        hasDanglingRules: backend.offloadRules.contains { !$0.isHealthy }
                    ))
                    // Typed path: host not connected.
                    unavailable.append(SymlinkHealthReport.UnavailableVolume(
                        volumeId: backend.id,
                        expectedMount: backend.mount,
                        hostName: backend.host,
                        imagePath: backend.resolvedImagePath,
                        reason: .hostNotConnected
                    ))
                } else {
                    // Host IS mounted but the volume is not — implies a stale/failed attach.
                    // Check for a fallback directory first (BackendRebuilt state).
                    let home = fm.homeDirectoryForCurrentUser.path
                    let fallbackPath = (home as NSString)
                        .appendingPathComponent("DevDrive/\(backend.id)-fallback")
                    var fallbackIsDir: ObjCBool = false
                    let fallbackExists = fm.fileExists(atPath: fallbackPath,
                                                       isDirectory: &fallbackIsDir)
                        && fallbackIsDir.boolValue

                    if fallbackExists {
                        // BackendRebuilt: volume mounted, fallback dir present.
                        // We cannot run lsof synchronously here; surface with empty holders
                        // so the UI can trigger an async quiescence check via resync(backendId:).
                        unavailable.append(SymlinkHealthReport.UnavailableVolume(
                            volumeId: backend.id,
                            expectedMount: backend.mount,
                            hostName: backend.host,
                            imagePath: backend.resolvedImagePath,
                            reason: .fallbackPendingReclaim(fallbackSize: 0, holders: [])
                        ))
                    } else {
                        // Host mounted, volume absent, no fallback → Class A stale half-attach.
                        // Emit a conservative .classA degraded signal so the orchestrator's
                        // pre-flight resolves it on the next attach attempt.
                        let sig = CorruptionSignature(
                            hdiutilErrno: EBUSY,
                            containerVisible: false,
                            shadowAttachOutcome: .notAttempted
                        )!
                        unavailable.append(SymlinkHealthReport.UnavailableVolume(
                            volumeId: backend.id,
                            expectedMount: backend.mount,
                            hostName: backend.host,
                            imagePath: backend.resolvedImagePath,
                            reason: .degraded(class_: .classA, signature: sig)
                        ))
                    }
                }
            }
        }

        return SymlinkHealthReport(
            danglingRules: dangling,
            missingHostVolumes: missingHosts,
            unavailableVolumes: unavailable,
            scannedAt: now
        )
    }
}

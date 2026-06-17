import Foundation

// MARK: - ResyncReport

/// Result returned by `MountOrchestrator.resync(backendId:requireQuiescence:)`.
///
/// A `ResyncReport` is produced only when the reclaim sequence completes without throwing.
/// All error paths surface as thrown `ResyncError` values.
public struct ResyncReport: Sendable {

    /// The backend id that was reclaimed (e.g. `"901DEVLIB"`).
    public let backendId: String

    /// Byte count of the fallback directory that was deleted on successful reclaim.
    public let fallbackBytesReclaimed: Int64

    /// Whether the rsync phase completed with exit code 0.
    public let rsynced: Bool

    /// Whether the `diff -rq` verification passed.
    public let verified: Bool

    /// Convenience: human-readable size of the reclaimed fallback.
    public var fallbackSizeLabel: String {
        let gb = Double(fallbackBytesReclaimed) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(fallbackBytesReclaimed) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - ResyncError

/// Errors thrown by `MountOrchestrator.resync(backendId:requireQuiescence:)`.
public enum ResyncError: Error, Sendable {

    /// No backend with the given id was found in the fleet registry.
    case backendNotFound(String)

    /// The expected fallback directory does not exist or is not a directory.
    case noFallbackDirectory(String)

    /// One or more processes hold open file descriptors in the fallback directory
    /// and `requireQuiescence` is `true`.
    case fallbackInUse(holders: [HolderProcess])

    /// The backend's declared mount path does not exist (volume not mounted).
    case volumeNotMounted(String)

    /// Volume free space is insufficient for safe reclaim (< 1.2× fallback size).
    case insufficientSpace(required: Int64, available: Int64)

    /// Another reclaim for the same backend is already in progress.
    case reclaimInProgress(String)

    /// The rsync transfer step failed.
    case rsyncFailed(String)

    /// The `diff -rq` post-rsync verification found differences.
    case verifyFailed(String)

    /// The backend's corruption signature is non-null — the volume is unhealthy
    /// and must clear before a reclaim is permitted (prevents rsync from fallback
    /// onto a damaged volume).
    case signatureUnresolved(String)
}

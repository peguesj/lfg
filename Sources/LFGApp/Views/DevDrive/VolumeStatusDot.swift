import SwiftUI
import LFGKit

// MARK: - VolumeStatus

/// Four-state health classification for a `VolumeBackend`.
enum VolumeStatus {
    /// The volume's mount point does not exist on the filesystem.
    case unmounted
    /// Mounted and every `OffloadRule` symlink is healthy.
    case healthy
    /// Mounted but at least one `OffloadRule` symlink is broken or missing.
    case drift
    /// An explicit error condition (e.g. filesystem query failure).
    case error
}

// MARK: - VolumeStatusDot

/// An 8-pt coloured circle that communicates `VolumeStatus` at a glance.
///
/// Colour mapping:
/// - `.unmounted` → system gray
/// - `.healthy`   → system green
/// - `.drift`     → system orange
/// - `.error`     → system red
///
/// Usage:
/// ```swift
/// VolumeStatusDot(status: .healthy)
/// ```
struct VolumeStatusDot: View {

    let status: VolumeStatus

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
    }

    // MARK: Private

    private var dotColor: Color {
        switch status {
        case .unmounted: return .secondary
        case .healthy:   return .green
        case .drift:     return .orange
        case .error:     return .red
        }
    }
}

// MARK: - VolumeStatus derivation helper

extension VolumeStatus {

    /// Derives a `VolumeStatus` from a `VolumeBackend`.
    ///
    /// - Uses `FileManager.default.fileExists(atPath:)` to check whether the
    ///   volume's mount point is present.
    /// - When mounted, inspects every `OffloadRule.isHealthy` to choose between
    ///   `.healthy` and `.drift`.
    ///
    /// - Parameter backend: The volume whose health to evaluate.
    /// - Returns: The computed `VolumeStatus`.
    static func derive(from backend: VolumeBackend) -> VolumeStatus {
        guard FileManager.default.fileExists(atPath: backend.mount) else {
            return .unmounted
        }
        let rules = backend.offloadRules
        guard !rules.isEmpty else { return .healthy }
        return rules.allSatisfy(\.isHealthy) ? .healthy : .drift
    }
}

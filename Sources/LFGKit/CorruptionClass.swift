import Foundation

// MARK: - CorruptionClass

/// Five-class failure taxonomy for APFS sparseimage attach failures.
///
/// Derived from `corruption-history-taxonomy.md` (LFG-93) and the differential
/// diagnosis flowchart in §2 of that document.
///
/// - `classA`: Stale half-attach — image attached to device node but no `/Volumes/` mount.
///             Autonomous fix: `hdiutil detach -force` + re-attach. No data loss.
/// - `classB`: APFS superblock corruption — errno 5 at block 0. Route to recovery agent.
/// - `classC`: Container metadata destroyed — btree node zeroed. Route to recovery agent.
/// - `classD`: Sparsebundle band damage — bad block in a single band file. Recovery agent.
/// - `classE`: Permission ghost — volume mounted but root dir unreadable. Autonomous fix.
///
/// Usage:
/// ```swift
/// let cls = CorruptionClassifier.classify(signature)
/// if cls.isAutonomousReclaimable {
///     // run detach + reattach or chmod without invoking recovery agent
/// } else {
///     // route to lfg-devdrive-recovery-agent
/// }
/// ```
public enum CorruptionClass: String, Codable, Sendable, CaseIterable {

    /// Stale half-attach: image is attached to a kernel device node but no APFS container
    /// or `/Volumes/<name>` mount exists. `hdiutil info` shows the image; `diskutil list`
    /// shows no APFS container under the outer disk node.
    ///
    /// Autonomous fix: `hdiutil detach -force <outerDev>` followed by plain re-attach.
    case classA

    /// APFS superblock corruption: `hdiutil attach` fails with errno 5 (`EIO`) at block 0
    /// ("superblock invalid"). Shadow attach succeeds; `fsck_apfs -yn` reports errors at
    /// the container superblock or checkpoint.
    ///
    /// Route to recovery agent for rebuild on a new v2 sparseimage.
    case classB

    /// Container metadata destruction: attach succeeds, container is visible, but
    /// `diskutil mount` fails ("no mountable file systems") and `fsck_apfs -yn` aborts
    /// at the extent-ref, fsroot, or object-map btree check.
    ///
    /// Route to recovery agent; no stock tooling repair path.
    case classC

    /// Band damage (`.sparsebundle` only): attach and mount succeed but `fsck_apfs -yn`
    /// reports bad blocks in a specific band file. Partial data loss possible.
    ///
    /// Route to recovery agent for band repair or rebuild.
    case classD

    /// Permission ghost: volume is mounted but the root directory is unreadable
    /// (mode 0o100 or 0o111). Data is intact; access is blocked.
    ///
    /// Autonomous fix: `chmod 0750 /Volumes/<name>` (uid check first) or
    /// detach + `hdiutil attach -owners off`.
    case classE
}

// MARK: - Autonomous reclaim gate

public extension CorruptionClass {

    /// Whether this failure class can be resolved autonomously without invoking the
    /// `devdrive-recovery-agent`.
    ///
    /// `true` for Class A (detach + reattach) and Class E (chmod or owners-off reattach).
    /// `false` for Class B, C, D — these require the supervised recovery path.
    var isAutonomousReclaimable: Bool {
        self == .classA || self == .classE
    }

    /// Human-readable failure name for logs and notifications.
    var displayName: String {
        switch self {
        case .classA: return "Stale Half-Attach"
        case .classB: return "APFS Superblock Corruption"
        case .classC: return "Container Metadata Destruction"
        case .classD: return "Sparsebundle Band Damage"
        case .classE: return "Permission Ghost"
        }
    }

    /// Short severity label for APM event payloads and notification bodies.
    var severityLabel: String {
        switch self {
        case .classA: return "transient"
        case .classB: return "critical"
        case .classC: return "critical"
        case .classD: return "warning"
        case .classE: return "recoverable"
        }
    }
}

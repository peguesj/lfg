import Foundation

// MARK: - ShadowOutcome

/// Outcome of a readonly shadow-attach probe used during Class B/C discrimination.
///
/// Shadow attach is only attempted when the primary attach failed (`hdiutil_attach_errno != nil`).
/// When the primary attach succeeded (errno nil), use `.notAttempted`.
public enum ShadowOutcome: Codable, Equatable, Sendable {

    /// Shadow attach was not attempted (primary attach succeeded or Class A pre-flight cut in).
    case notAttempted

    /// Shadow attach returned a device node; `fsck_apfs -yn` may or may not have found errors.
    ///
    /// - Parameter fsckClean: `true` when `fsck_apfs -yn` exited 0 (no errors found).
    case success(fsckClean: Bool)

    /// Shadow attach failed with the given reason string (e.g. "Resource temporarily unavailable").
    case failure(reason: String)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case kind
        case fsckClean = "fsck_clean"
        case reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "not_attempted":
            self = .notAttempted
        case "success":
            let clean = try c.decodeIfPresent(Bool.self, forKey: .fsckClean) ?? true
            self = .success(fsckClean: clean)
        case "failure":
            let reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
            self = .failure(reason: reason)
        default:
            self = .notAttempted
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notAttempted:
            try c.encode("not_attempted", forKey: .kind)
        case .success(let fsckClean):
            try c.encode("success", forKey: .kind)
            try c.encode(fsckClean, forKey: .fsckClean)
        case .failure(let reason):
            try c.encode("failure", forKey: .kind)
            try c.encode(reason, forKey: .reason)
        }
    }
}

// MARK: - CorruptionSignature

/// Three-tuple signal used by `CorruptionClassifier` to assign a `CorruptionClass`.
///
/// Mirrors the `(hdiutil_attach_errno, container_visible, shadow_attach_outcome)` taxonomy
/// from `corruption-history-taxonomy.md` §4 (LFG-93).
///
/// Usage:
/// ```swift
/// // Class A — stale half-attach
/// let sig = CorruptionSignature(
///     hdiutilErrno: EBUSY,
///     containerVisible: false,
///     shadowAttachOutcome: .notAttempted
/// )!
/// let cls = CorruptionClassifier.classify(sig)  // → .classA
/// ```
public struct CorruptionSignature: Codable, Equatable, Sendable {

    // MARK: Properties

    /// The errno returned by a failed `hdiutil attach` attempt, or `nil` when attach succeeded.
    ///
    /// Canonical values from the corpus:
    /// - `nil`   — attach returned exit 0 (success; container/mount presence still unconfirmed)
    /// - `EBUSY` (16) — image already attached to a stale device node (Class A indicator)
    /// - `EIO`   (5)  — superblock invalid / errno 5 at block 0 (Class B indicator)
    public let hdiutilErrno: Int32?

    /// Whether `diskutil list /dev/diskN` showed an APFS container under the device node
    /// obtained after attach (or from `hdiutil info` in the pre-flight check).
    ///
    /// `false` when no device node was obtained at all (attach failed before device
    /// reservation). `false` in Class A (device present but no container under it).
    /// `true` in Class B/C/D/E (container is visible after attach).
    public let containerVisible: Bool

    /// Outcome of the shadow-attach probe, if it was attempted.
    ///
    /// Only relevant when `hdiutilErrno != nil` (primary attach failed). For Class A
    /// the pre-flight cuts in before the shadow probe, so this is `.notAttempted`.
    public let shadowAttachOutcome: ShadowOutcome

    // MARK: Failable init

    /// Creates a `CorruptionSignature` with the given tuple values.
    ///
    /// Returns `nil` when the combination is internally inconsistent:
    /// - Shadow attach succeeded (`success`) requires a prior failed primary attach
    ///   (`hdiutilErrno != nil`). A succeeded primary attach + shadow success is contradictory.
    ///
    /// - Parameters:
    ///   - hdiutilErrno: The errno from a failed attach, or `nil` on success.
    ///   - containerVisible: Whether an APFS container was observed under the device node.
    ///   - shadowAttachOutcome: The shadow-probe result.
    public init?(
        hdiutilErrno: Int32?,
        containerVisible: Bool,
        shadowAttachOutcome: ShadowOutcome
    ) {
        // Shadow success implies primary attach failed.
        if case .success = shadowAttachOutcome, hdiutilErrno == nil {
            return nil
        }
        self.hdiutilErrno = hdiutilErrno
        self.containerVisible = containerVisible
        self.shadowAttachOutcome = shadowAttachOutcome
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case hdiutilErrno       = "hdiutil_errno"
        case containerVisible   = "container_visible"
        case shadowAttachOutcome = "shadow_attach_outcome"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hdiutilErrno       = try c.decodeIfPresent(Int32.self, forKey: .hdiutilErrno)
        containerVisible   = try c.decode(Bool.self, forKey: .containerVisible)
        shadowAttachOutcome = try c.decode(ShadowOutcome.self, forKey: .shadowAttachOutcome)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(hdiutilErrno, forKey: .hdiutilErrno)
        try c.encode(containerVisible, forKey: .containerVisible)
        try c.encode(shadowAttachOutcome, forKey: .shadowAttachOutcome)
    }
}

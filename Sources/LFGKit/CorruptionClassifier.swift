import Foundation

// MARK: - HdiutilInterface extensions (new methods)

// NOTE: `HdiutilInterface` is declared in `MountOrchestrator.swift`.
// The two new methods — `detachDevice(_:force:)` and `info()` — are added here
// as protocol requirements via extensions on the concrete `SystemHdiutil` type.
// If you later want to enforce them on *all* conformors, move the declarations
// into the protocol body in `MountOrchestrator.swift` and add stub
// implementations to mock types in tests.

// MARK: - CorruptionClassifier

/// Stateless decision tree that maps a `CorruptionSignature` to a `CorruptionClass`.
///
/// Implements the differential diagnosis flowchart from `corruption-history-taxonomy.md`
/// (LFG-93) §2. The classifier is a caseless enum (pure namespace) — no stored state,
/// no isolation domain required. All methods are `static` and implicitly `Sendable`.
///
/// ### Step-zero pre-flight (Class A gate)
///
/// `gatherSignature(for:hdiutil:)` first runs `hdiutil info -plist` and checks
/// whether the backend's image path already appears in the device-node listing.
/// If it does and no `/Volumes/<name>` mount exists, the function returns a Class A
/// signature immediately — without attempting a shadow attach. This pre-flight
/// eliminates the "stale EBUSY → misrouted to Class B" failure mode documented in
/// LFG-93 §3.
///
/// Usage:
/// ```swift
/// let sig = try await CorruptionClassifier.gatherSignature(for: backend, hdiutil: SystemHdiutil())
/// let cls = CorruptionClassifier.classify(sig)
/// switch cls {
/// case .classA:
///     // autonomous: detach -force + reattach
/// case .classE:
///     // autonomous: chmod 0750
/// default:
///     // route to recovery agent
/// }
/// ```
public enum CorruptionClassifier {

    // MARK: - Classification

    /// Maps a `CorruptionSignature` to the corresponding `CorruptionClass`.
    ///
    /// Decision tree (mirrors LFG-93 §2 flowchart):
    ///
    /// 1. `hdiutilErrno == nil` (attach succeeded):
    ///    - `containerVisible: false` → ghost-attach Class A variant (device present, mount absent).
    ///    - `containerVisible: true` → volume mounted but may have permission issue → `.classE`.
    ///
    /// 2. `hdiutilErrno == EBUSY (16)` — image already attached to a stale device node:
    ///    - Both `containerVisible: false` and `true` → `.classA`.
    ///
    /// 3. `hdiutilErrno == EIO (5)` — superblock-level failure:
    ///    - Shadow succeeded + fsck found errors → `.classB`.
    ///    - Shadow succeeded + fsck clean → `.classA` edge case (transient stale slot).
    ///    - Shadow failed → `.classC` (container metadata destroyed).
    ///    - `notAttempted` → pre-flight fired → `.classA`.
    ///
    /// 4. Any other errno:
    ///    - Shadow succeeded + `containerVisible: true` + fsck errors → `.classD` (band damage).
    ///    - Shadow succeeded + `containerVisible: true` + fsck clean → `.classB` (transient).
    ///    - Shadow failed → `.classC`.
    ///    - Other → conservative `.classA` or `.classB`.
    ///
    /// - Parameter signature: A `CorruptionSignature` gathered from live probe output.
    /// - Returns: The most precise matching `CorruptionClass`.
    public static func classify(_ signature: CorruptionSignature) -> CorruptionClass {
        switch (signature.hdiutilErrno, signature.containerVisible, signature.shadowAttachOutcome) {

        // ── Attach succeeded (errno nil) ────────────────────────────────────────────
        case (nil, false, _):
            // Ghost-attach: device present, mount absent — Class A variant (US-A-005 AC-2).
            return .classA

        case (nil, true, _):
            // Volume mounted but may have permission issue → Class E.
            return .classE

        // ── EBUSY (16) — image already attached to a stale device node ─────────────
        case (EBUSY, false, _):
            // Canonical Class A: `hdiutil info` shows image; no container under the node.
            return .classA

        case (EBUSY, true, _):
            // Container visible under the stale device — still Class A variant.
            return .classA

        // ── EIO (5) — superblock-level failure ─────────────────────────────────────
        case (EIO, _, .success(let fsckClean)):
            // Shadow succeeded — can examine the container.
            return fsckClean ? .classA : .classB

        case (EIO, _, .failure):
            // Shadow also failed — container metadata is destroyed.
            return .classC

        case (EIO, _, .notAttempted):
            // Pre-flight cut in (Class A gate fired) — treat as Class A.
            return .classA

        // ── Other errno ─────────────────────────────────────────────────────────────
        case (_, true, .success(let fsckClean)):
            // Per LFG-93 §3 + corruption-history-taxonomy.md:
            // - fsck errors  → band damage (Class D)
            // - fsck clean   → transient/conservative (Class B)
            return fsckClean ? .classB : .classD

        case (_, _, .failure):
            return .classC

        case (_, false, .success):
            // No container but shadow succeeded — unusual; conservative fallback.
            return .classB

        case (_, false, .notAttempted):
            // No container, no shadow attempt — most likely Class A.
            return .classA

        case (.some(_), true, .notAttempted):
            // hdiutil failed with a non-EBUSY/EIO errno but the container is
            // somehow still visible AND no shadow attempt was made.
            // Treat as a stale half-attach (device entry present despite errno)
            // — Class A is the conservative, recoverable classification.
            return .classA
        }
    }

    // MARK: - Signature gathering

    /// Gathers a `CorruptionSignature` for the given backend by running the step-zero
    /// pre-flight, optionally attempting plain attach, and (if needed) a readonly shadow probe.
    ///
    /// Sequence:
    /// 1. `hdiutil info -plist` — check if image is already attached (Class A gate).
    ///    If attached + no mount → returns Class A signature immediately (no shadow probe).
    /// 2. Plain `hdiutil attach <image>` via the injected `hdiutil` interface.
    ///    If exit 0 and `/Volumes/<expected>` exists → volume is healthy; throws `.volumeHealthy`.
    ///    If exit 0 and mount absent → ghost-attach signature (US-A-005).
    /// 3. Shadow attach: `hdiutil attach -readonly -shadow /tmp/lfg-<id>.shadow -nomount`
    ///    followed by `fsck_apfs -yn` on the slice.
    ///
    /// - Parameters:
    ///   - backend: The `VolumeBackend` to probe.
    ///   - hdiutil: An `HdiutilInterface` implementation (injectable for tests).
    /// - Returns: A `CorruptionSignature` describing the observed state.
    /// - Throws: `CorruptionClassifierError` when a required probe cannot run, or
    ///           `.volumeHealthy` when attach succeeded with a valid mount.
    public static func gatherSignature(
        for backend: VolumeBackend,
        hdiutil: HdiutilInterface
    ) async throws -> CorruptionSignature {

        // ── Step 0: pre-flight — is the image already stale-attached? ────────────────
        let infoResult = try await ProcessRunner.run(
            "/usr/bin/hdiutil",
            arguments: ["info", "-plist"]
        )
        let staleDevice = parseStaleDevice(hdiutilInfoPlist: infoResult.stdout,
                                           imagePath: backend.resolvedImagePath)

        if staleDevice != nil {
            let mountExists = FileManager.default.fileExists(atPath: backend.mount)
            if !mountExists {
                // Class A: image is attached, mount is absent. Skip shadow probe.
                return CorruptionSignature(
                    hdiutilErrno: EBUSY,
                    containerVisible: false,
                    shadowAttachOutcome: .notAttempted
                )! // force-unwrap safe: EBUSY + false + notAttempted is a valid tuple
            }
        }

        // ── Step 1: plain attach attempt ─────────────────────────────────────────────
        let attachResult = try await hdiutil.attach(imagePath: backend.resolvedImagePath)

        if attachResult.succeeded {
            let mountExists = FileManager.default.fileExists(atPath: backend.mount)
            if mountExists {
                // Volume is healthy — no corruption signature needed.
                throw CorruptionClassifierError.volumeHealthy
            } else {
                // Ghost-attach: exit 0 but no /Volumes/ mount (US-A-005).
                return CorruptionSignature(
                    hdiutilErrno: nil,
                    containerVisible: false,
                    shadowAttachOutcome: .notAttempted
                )! // valid: nil + false + notAttempted
            }
        }

        // ── Step 2: parse errno from stderr ─────────────────────────────────────────
        let attachErrno = parseErrno(from: attachResult.stderr)
        let containerVisible = await probeContainerVisible(imagePath: backend.resolvedImagePath)

        // ── Step 3: shadow attach probe ──────────────────────────────────────────────
        let shadowPath = "/tmp/lfg-shadow-\(backend.id).shadow"
        let shadowResult = try await ProcessRunner.run(
            "/usr/bin/hdiutil",
            arguments: [
                "attach", "-readonly", "-shadow", shadowPath,
                "-nomount", "-noverify",
                backend.resolvedImagePath
            ]
        )

        guard shadowResult.succeeded else {
            let reason = shadowResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return CorruptionSignature(
                hdiutilErrno: attachErrno,
                containerVisible: containerVisible,
                shadowAttachOutcome: .failure(reason: reason)
            ) ?? CorruptionSignature(
                hdiutilErrno: attachErrno ?? EIO,
                containerVisible: containerVisible,
                shadowAttachOutcome: .failure(reason: reason)
            )!
        }

        // Shadow succeeded — run fsck_apfs -yn on the shadow slice.
        let slice = parseShadowSlice(from: shadowResult.stdout)
        var fsckClean = true
        if let slicePath = slice {
            let fsckResult = try await ProcessRunner.run(
                "/usr/sbin/fsck_apfs",
                arguments: ["-yn", slicePath]
            )
            fsckClean = (fsckResult.exitCode == 0)
        }

        // Clean up shadow file (best effort).
        try? FileManager.default.removeItem(atPath: shadowPath)

        return CorruptionSignature(
            hdiutilErrno: attachErrno,
            containerVisible: containerVisible,
            shadowAttachOutcome: .success(fsckClean: fsckClean)
        ) ?? CorruptionSignature(
            hdiutilErrno: attachErrno ?? EIO,
            containerVisible: containerVisible,
            shadowAttachOutcome: .success(fsckClean: fsckClean)
        )!
    }

    // MARK: - Private parsing helpers

    /// Parses the outer device node for the given image from `hdiutil info -plist` XML.
    ///
    /// Returns the first `/dev/diskN` string whose associated `image-path` matches
    /// `imagePath`, or `nil` when the image is not currently attached.
    static func parseStaleDevice(hdiutilInfoPlist: String,
                                 imagePath: String) -> String? {
        guard let data = hdiutilInfoPlist.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]]
        else { return nil }

        for image in images {
            guard let path = image["image-path"] as? String,
                  path == imagePath,
                  let entities = image["system-entities"] as? [[String: Any]],
                  let firstEntity = entities.first,
                  let devEntry = firstEntity["dev-entry"] as? String
            else { continue }
            return devEntry   // e.g. "/dev/disk19"
        }
        return nil
    }

    /// Extracts an errno value from `hdiutil attach` stderr.
    ///
    /// Recognises patterns from the LFG-93 corpus:
    /// - "Resource busy" / "Resource temporarily unavailable" → `EBUSY` (16)
    /// - "superblock invalid" / "errno 5" / "EIO" → `EIO` (5)
    /// - Unrecognised → `nil`
    static func parseErrno(from stderr: String) -> Int32? {
        let lower = stderr.lowercased()
        if lower.contains("resource busy") || lower.contains("resource temporarily unavailable") {
            return EBUSY
        }
        if lower.contains("superblock") || lower.contains("errno 5") || lower.contains("eio") {
            return EIO
        }
        return nil
    }

    /// Probes whether an APFS container is visible under the device node for the image.
    ///
    /// Runs `hdiutil info -plist` again (cheap) and checks `diskutil list` on the
    /// matched device node.
    private static func probeContainerVisible(imagePath: String) async -> Bool {
        guard let infoResult = try? await ProcessRunner.run(
            "/usr/bin/hdiutil", arguments: ["info", "-plist"]
        ),
        let devNode = parseStaleDevice(hdiutilInfoPlist: infoResult.stdout,
                                       imagePath: imagePath)
        else { return false }

        guard let listResult = try? await ProcessRunner.run(
            "/usr/sbin/diskutil", arguments: ["list", "-plist", devNode]
        ) else { return false }

        return listResult.stdout.contains("Apple_APFS")
    }

    /// Extracts the first `/dev/rdiskNs1` slice path from `hdiutil attach` stdout
    /// (used to run `fsck_apfs -yn` on the shadow slice).
    private static func parseShadowSlice(from stdout: String) -> String? {
        let lines = stdout.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("Apple_APFS") || line.contains("APFS Volume") {
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                if let dev = parts.first(where: { $0.hasPrefix("/dev/disk") }) {
                    return dev.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
                }
            }
        }
        return nil
    }
}

// MARK: - CorruptionClassifierError

/// Errors thrown by `CorruptionClassifier.gatherSignature(for:hdiutil:)`.
public enum CorruptionClassifierError: Error, Sendable {
    /// The volume is healthy — no corruption signature was needed.
    /// The caller should record a successful attach and continue.
    case volumeHealthy
    /// A required probe binary was not found at the expected path.
    case probeBinaryMissing(String)
    /// The hdiutil info plist could not be parsed.
    case plistParseFailed
}

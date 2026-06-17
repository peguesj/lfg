import Foundation

// MARK: - RelocationPhase

/// Tracks progress through a sparseimage move operation.
public enum RelocationPhase: Sendable, Equatable {
    case idle
    case preflight
    case detaching
    case copying(progress: Double)   // 0.0 … 1.0
    case updatingFleet
    case reattaching
    case cleaningUp
    case complete
    case failed(String)
}

// MARK: - RelocationCoordinator

/// Moves a `VolumeBackend`'s sparseimage from its current location to a new
/// destination directory on a different host volume.
///
/// Safety contract:
/// - The original sparseimage is **not deleted** until the copy is verified and
///   `fleet.json` has been atomically updated.
/// - If any step fails the coordinator surfaces a `.failed` phase and leaves
///   the original image untouched.
///
/// Sequence:
/// 1. Preflight — verify source exists and destination has sufficient free space.
/// 2. Detach — `hdiutil detach <mount>` if the volume is currently mounted.
/// 3. Copy — `rsync -aH --progress` source → destination.
/// 4. Update fleet.json — patch the `image` field for the matching drive entry.
/// 5. Re-attach — `hdiutil attach <newImagePath> -mountpoint <mount> -nobrowse`.
/// 6. Clean up — remove the original sparseimage after successful re-attach.
@MainActor
public final class RelocationCoordinator: ObservableObject {

    // MARK: Published state

    @Published public private(set) var phase: RelocationPhase = .idle
    @Published public private(set) var statusMessage = ""

    // MARK: Dependencies

    private let runner: ShellRunnerProtocol

    public init(runner: ShellRunnerProtocol = DefaultShellRunner()) {
        self.runner = runner
    }

    // MARK: Public API

    /// Executes the full relocation pipeline.
    ///
    /// - Parameters:
    ///   - backend: The `VolumeBackend` to relocate.
    ///   - destinationDirectory: The target directory on the new host (e.g.
    ///     `/Volumes/YJ_MORE/DevDrive/`). The sparseimage filename is preserved.
    ///   - fleetURL: URL of `fleet.json` to patch.
    public func relocate(
        backend: VolumeBackend,
        destinationDirectory: String,
        fleetURL: URL
    ) async {
        let sourcePath = backend.resolvedImagePath
        let imageName  = (sourcePath as NSString).lastPathComponent
        let destPath   = (destinationDirectory as NSString).appendingPathComponent(imageName)

        do {
            // 1 — Preflight
            phase = .preflight
            statusMessage = "Checking available space…"
            try preflightCheck(sourcePath: sourcePath, destinationDirectory: destinationDirectory)

            // 2 — Detach if mounted
            phase = .detaching
            statusMessage = "Detaching \(backend.id)…"
            try await detachIfMounted(mountPoint: backend.mount)

            // 3 — Copy
            phase = .copying(progress: 0)
            statusMessage = "Copying sparseimage…"
            try await copyImage(from: sourcePath, to: destPath)

            // 4 — Update fleet.json
            phase = .updatingFleet
            statusMessage = "Updating fleet.json…"
            try updateFleet(fleetURL: fleetURL, backendID: backend.id, newImagePath: destPath)

            // 5 — Re-attach
            phase = .reattaching
            statusMessage = "Re-attaching volume…"
            try await reattach(imagePath: destPath, mountPoint: backend.mount)

            // 6 — Clean up original
            phase = .cleaningUp
            statusMessage = "Removing original sparseimage…"
            try FileManager.default.removeItem(atPath: sourcePath)

            phase = .complete
            statusMessage = "Relocation complete."

        } catch {
            phase = .failed(error.localizedDescription)
            statusMessage = "Relocation failed: \(error.localizedDescription)"
        }
    }

    /// Reset to idle so the sheet can be reused.
    public func reset() {
        phase = .idle
        statusMessage = ""
    }

    // MARK: Private steps

    private func preflightCheck(sourcePath: String, destinationDirectory: String) throws {
        let fm = FileManager.default

        guard fm.fileExists(atPath: sourcePath) else {
            throw RelocationError.sourceNotFound(sourcePath)
        }

        let attrs = try fm.attributesOfItem(atPath: sourcePath)
        let sourceSize = attrs[.size] as? Int64 ?? 0

        let destURL = URL(fileURLWithPath: destinationDirectory)
        let destValues = try destURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        let available  = Int64(destValues.volumeAvailableCapacity ?? 0)

        guard available > sourceSize + 512 * 1_024 * 1_024 else {
            throw RelocationError.insufficientSpace(available: available, required: sourceSize)
        }
    }

    private func detachIfMounted(mountPoint: String) async throws {
        let check = try await runner.shell("hdiutil info -plist 2>/dev/null | grep -q '\(mountPoint)' && echo yes || echo no")
        guard check.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" else { return }

        let result = try await runner.shell("hdiutil detach '\(mountPoint)' -quiet 2>&1")
        if !result.succeeded {
            throw RelocationError.detachFailed(result.stderr)
        }
    }

    private func copyImage(from source: String, to destination: String) async throws {
        // rsync -aH preserves sparse file extents; --inplace writes directly to dest.
        let result = try await runner.shell(
            "rsync -aH --inplace '\(source)' '\(destination)' 2>&1"
        )
        if !result.succeeded {
            throw RelocationError.copyFailed(result.stderr)
        }
        phase = .copying(progress: 1.0)
    }

    private func updateFleet(fleetURL: URL, backendID: String, newImagePath: String) throws {
        var raw = (try? JSONSerialization.jsonObject(with: try Data(contentsOf: fleetURL))) as? [String: Any] ?? [:]
        var drives = raw["drives"] as? [[String: Any]] ?? []

        guard let idx = drives.firstIndex(where: { ($0["id"] as? String) == backendID }) else {
            throw RelocationError.backendNotFound(backendID)
        }
        drives[idx]["image"] = newImagePath
        raw["drives"] = drives

        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fleetURL, options: .atomic)
    }

    private func reattach(imagePath: String, mountPoint: String) async throws {
        let result = try await runner.shell(
            "hdiutil attach '\(imagePath)' -mountpoint '\(mountPoint)' -nobrowse -quiet 2>&1"
        )
        if !result.succeeded {
            throw RelocationError.reattachFailed(result.stderr)
        }
    }
}

// MARK: - RelocationError

public enum RelocationError: LocalizedError {
    case sourceNotFound(String)
    case insufficientSpace(available: Int64, required: Int64)
    case detachFailed(String)
    case copyFailed(String)
    case backendNotFound(String)
    case reattachFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let p):
            return "Source image not found: \(p)"
        case .insufficientSpace(let avail, let req):
            let fmt = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_073_741_824) }
            return "Insufficient space — need \(fmt(req)), only \(fmt(avail)) available."
        case .detachFailed(let msg):
            return "Could not detach volume: \(msg)"
        case .copyFailed(let msg):
            return "rsync copy failed: \(msg)"
        case .backendNotFound(let id):
            return "Backend '\(id)' not found in fleet.json"
        case .reattachFailed(let msg):
            return "Re-attach after move failed: \(msg)"
        }
    }
}

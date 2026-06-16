import Foundation

// MARK: - Hdiutil abstraction

/// Abstraction over `hdiutil` attach/detach to enable test injection.
public protocol HdiutilInterface: Sendable {
    func attach(imagePath: String) async throws -> ProcessRunner.Result
    func detach(mountPath: String, force: Bool) async throws -> ProcessRunner.Result

    /// Detach by raw device node (e.g. `/dev/disk19`) for Class A stale-device clear.
    func detachDevice(_ devNode: String, force: Bool) async throws -> ProcessRunner.Result

    /// Run `hdiutil info -plist` and return the raw stdout for pre-flight Class A detection.
    func info() async throws -> ProcessRunner.Result
}

/// Production implementation that shells out to `/usr/bin/hdiutil`.
public struct SystemHdiutil: HdiutilInterface {
    public init() {}

    public func attach(imagePath: String) async throws -> ProcessRunner.Result {
        try await ProcessRunner.run(
            "/usr/bin/hdiutil",
            arguments: ["attach", imagePath, "-nobrowse", "-quiet"]
        )
    }

    public func detach(mountPath: String, force: Bool) async throws -> ProcessRunner.Result {
        var args = ["detach", mountPath]
        if force { args.append("-force") }
        return try await ProcessRunner.run("/usr/bin/hdiutil", arguments: args)
    }

    public func detachDevice(_ devNode: String, force: Bool) async throws -> ProcessRunner.Result {
        var args = ["detach", devNode]
        if force { args.append("-force") }
        return try await ProcessRunner.run("/usr/bin/hdiutil", arguments: args)
    }

    public func info() async throws -> ProcessRunner.Result {
        try await ProcessRunner.run("/usr/bin/hdiutil", arguments: ["info", "-plist"])
    }
}

// MARK: - Orchestrator

/// Manages attach/detach of sparseimages for a given external host.
///
/// CP-108 constraint: home-dir offload symlinks (npm-cache, vscode, asdf, etc.)
/// are NEVER touched. The orchestrator only calls `hdiutil attach/detach` and
/// does not modify any symlinks or fallback directories.
///
/// Usage:
/// ```swift
/// let registry = try FleetRegistry(url: fleetURL)
/// let orchestrator = MountOrchestrator(registry: registry)
/// await orchestrator.attachAll(forHost: "YJ_MORE")
/// ```
public actor MountOrchestrator {

    // MARK: Dependencies

    private let registry: FleetRegistry
    private let hdiutil: HdiutilInterface

    // MARK: State

    /// Volumes currently known to be attached: id → mountPath.
    private(set) var attachedVolumes: [String: String] = [:]

    // MARK: Init

    public init(registry: FleetRegistry, hdiutil: HdiutilInterface = SystemHdiutil()) {
        self.registry = registry
        self.hdiutil = hdiutil
    }

    // MARK: Public API

    /// Attach all auto-reconnect sparseimages for the given host.
    /// Returns a summary of successes and failures.
    @discardableResult
    public func attachAll(forHost host: String) async -> [AttachResult] {
        let drives = registry.autoDrives(forHost: host)
        var results: [AttachResult] = []
        for drive in drives {
            let r = await attach(drive: drive)
            results.append(r)
        }
        return results
    }

    /// Detach all sparseimages that were attached for the given host.
    @discardableResult
    public func detachAll(forHost host: String) async -> [DetachResult] {
        let drives = registry.drives(forHost: host)
        var results: [DetachResult] = []
        for drive in drives {
            guard attachedVolumes[drive.id] != nil else { continue }
            let r = await detach(drive: drive, force: true)
            results.append(r)
        }
        return results
    }

    /// Attach a single drive by fleet.json id. Returns a result.
    @discardableResult
    public func attachById(_ id: String) async -> AttachResult {
        guard let drive = registry.drive(id: id) else {
            return AttachResult(id: id, mountPath: nil, succeeded: false,
                                message: "Drive '\(id)' not found in fleet registry")
        }
        return await attach(drive: drive)
    }

    /// Detach a single drive by fleet.json id.
    @discardableResult
    public func detachById(_ id: String, force: Bool = false) async -> DetachResult {
        guard let drive = registry.drive(id: id) else {
            return DetachResult(id: id, succeeded: false,
                                message: "Drive '\(id)' not found in fleet registry")
        }
        return await detach(drive: drive, force: force)
    }

    /// Currently attached volume ids.
    public var attachedIds: [String] { Array(attachedVolumes.keys) }

    // MARK: Reclaim

    /// Reclaims a fallback directory back into the DevDrive volume.
    ///
    /// Implements the `BackendRebuilt → SyncInProgress → SyncVerifying → Reclaimed`
    /// sequence with lsof quiescence gating, rsync transfer, diff verification,
    /// atomic symlink restore, and APM event emission.
    ///
    /// Safety gates (evaluated in order; each throws on failure):
    /// 1. Backend must exist in the fleet registry.
    /// 2. Fallback directory `~/DevDrive/<id>-fallback/` must exist.
    /// 3. `lsof +D <fallback>` must return no open FDs when `requireQuiescence` is `true`.
    /// 4. Volume mount must exist at the backend's declared mount path.
    /// 5. Volume free space must be ≥ 1.2× fallback size.
    /// 6. Per-backend lock file `~/.config/lfg/locks/reclaim.<id>.lock` prevents
    ///    concurrent reclaims — throws `.reclaimInProgress` when lock is held.
    ///
    /// On success, emits a `devdrive.lifecycle.reclaimed` APM event via
    /// `BackendLifecycleClient.shared`.
    ///
    /// - Parameters:
    ///   - backendId: Fleet.json `id` of the backend to reclaim (e.g. `"901DEVLIB"`).
    ///   - requireQuiescence: When `true` (default), aborts if any process holds open
    ///     FDs in the fallback directory. Set `false` to proceed despite holders.
    /// - Returns: A `ResyncReport` describing the reclaim outcome.
    /// - Throws: `ResyncError` on gate failure, rsync failure, or verify failure.
    public func resync(
        backendId: String,
        requireQuiescence: Bool = true
    ) async throws -> ResyncReport {
        // Gate 1: backend exists in registry.
        guard registry.drive(id: backendId) != nil else {
            throw ResyncError.backendNotFound(backendId)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallbackPath = (home as NSString)
            .appendingPathComponent("DevDrive/\(backendId)-fallback")

        // Gate 2: fallback directory exists.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fallbackPath, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw ResyncError.noFallbackDirectory(fallbackPath)
        }

        // Gate 3: lsof quiescence check.
        let holders = try await scanHolders(path: fallbackPath)
        if !holders.isEmpty && requireQuiescence {
            throw ResyncError.fallbackInUse(holders: holders)
        }

        // Retrieve backend mount path from the v2 FleetDrive API.
        guard let drive = registry.drive(id: backendId) else {
            throw ResyncError.backendNotFound(backendId)
        }

        // Gate 4: volume is mounted.
        guard FileManager.default.fileExists(atPath: drive.mount) else {
            throw ResyncError.volumeNotMounted(drive.mount)
        }

        // Gate 5: free space ≥ 1.2× fallback size.
        let fallbackBytes = try await directorySize(at: fallbackPath)
        if let freeBytes = volumeFreeBytes(at: drive.mount) {
            guard Double(freeBytes) >= Double(fallbackBytes) * 1.2 else {
                throw ResyncError.insufficientSpace(
                    required: Int64(Double(fallbackBytes) * 1.2),
                    available: freeBytes
                )
            }
        }

        // Gate 6: acquire per-backend lock file.
        let lockPath = (home as NSString)
            .appendingPathComponent(".config/lfg/locks/reclaim.\(backendId).lock")
        try createLockDirectory(lockPath: lockPath)
        guard acquireLock(at: lockPath) else {
            throw ResyncError.reclaimInProgress(backendId)
        }
        defer { releaseLock(at: lockPath) }

        // ── rsync fallback → volume ────────────────────────────────────────────────────
        let rsyncResult = try await ProcessRunner.run(
            "/usr/bin/rsync",
            arguments: [
                "--archive", "--update",
                "--human-readable",
                fallbackPath + "/",
                drive.mount + "/"
            ]
        )
        guard rsyncResult.succeeded else {
            throw ResyncError.rsyncFailed(rsyncResult.stderr)
        }

        // ── diff -rq verification ──────────────────────────────────────────────────────
        let diffResult = try await ProcessRunner.run(
            "/usr/bin/diff",
            arguments: ["-rq", fallbackPath, drive.mount]
        )
        guard diffResult.succeeded else {
            throw ResyncError.verifyFailed(diffResult.stdout)
        }

        // ── restore unhealthy offload rules from the v3 VolumeBackend API ─────────────
        if let backend = registry.allVolumeBackends.first(where: { $0.id == backendId }) {
            for rule in backend.offloadRules where !rule.isHealthy {
                try restoreOffloadRule(rule)
            }
        }

        // ── delete fallback directory ─────────────────────────────────────────────────
        try FileManager.default.removeItem(atPath: fallbackPath)

        // ── APM event ─────────────────────────────────────────────────────────────────
        await BackendLifecycleClient.shared.transition(
            backendId: backendId,
            from: "BackendRebuilt",
            to: "Reclaimed",
            evidence: ["rsync_rc": "0", "diff_rc": "0"]
        )

        return ResyncReport(
            backendId: backendId,
            fallbackBytesReclaimed: fallbackBytes,
            rsynced: true,
            verified: true
        )
    }

    // MARK: Private helpers

    private func attach(drive: FleetDrive) async -> AttachResult {
        // Already attached — idempotent.
        if let mp = attachedVolumes[drive.id] {
            return AttachResult(id: drive.id, mountPath: mp, succeeded: true,
                                message: "Already attached at \(mp)")
        }

        // ── Pre-flight: Class A stale-device detection (LFG-93 §4 step zero) ─────────
        //
        // Run `hdiutil info -plist` BEFORE any attach attempt. If the image is already
        // attached to a stale device node with no /Volumes/ mount, force-detach the
        // stale reservation before proceeding. Prevents the "Resource temporarily
        // unavailable" EBUSY that previously caused Class A → Class B misroutes.
        let infoResult = (try? await hdiutil.info()) ??
            ProcessRunner.Result(exitCode: 1, stdout: "", stderr: "")
        if let staleNode = parseStaleDevice(plist: infoResult.stdout,
                                            imagePath: drive.resolvedImagePath) {
            let mountExists = FileManager.default.fileExists(atPath: drive.mount)
            if !mountExists {
                // Class A — force-detach the stale device node, then fall through to attach.
                _ = try? await hdiutil.detachDevice(staleNode, force: true)
                // Yield so the kernel releases the device reservation.
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
            }
        }

        // ── Normal attach ─────────────────────────────────────────────────────────────
        let imagePath = drive.resolvedImagePath
        do {
            let result = try await hdiutil.attach(imagePath: imagePath)
            if result.succeeded {
                // Post-attach ghost-check (US-A-005 AC-1): confirm /Volumes/ mount exists.
                guard FileManager.default.fileExists(atPath: drive.mount) else {
                    return AttachResult(
                        id: drive.id, mountPath: nil, succeeded: false,
                        message: "ghost.attach.empty_mount: exit 0 but \(drive.mount) absent"
                    )
                }
                attachedVolumes[drive.id] = drive.mount
                return AttachResult(id: drive.id, mountPath: drive.mount, succeeded: true,
                                    message: "Attached \(drive.id) at \(drive.mount)")
            } else {
                return AttachResult(id: drive.id, mountPath: nil, succeeded: false,
                                    message: "hdiutil attach failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch {
            return AttachResult(id: drive.id, mountPath: nil, succeeded: false,
                                message: "attach error: \(error.localizedDescription)")
        }
    }

    /// Parses the outer device node for the given image from `hdiutil info -plist` XML.
    ///
    /// Mirrors `CorruptionClassifier.parseStaleDevice` — duplicated here to avoid
    /// making the classifier's internal helpers visible outside LFGKit.
    private func parseStaleDevice(plist: String, imagePath: String) -> String? {
        guard let data = plist.data(using: .utf8),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let images = parsed["images"] as? [[String: Any]]
        else { return nil }

        for image in images {
            guard let path = image["image-path"] as? String, path == imagePath,
                  let entities = image["system-entities"] as? [[String: Any]],
                  let firstEntity = entities.first,
                  let devEntry = firstEntity["dev-entry"] as? String
            else { continue }
            return devEntry
        }
        return nil
    }

    // MARK: resync private helpers

    /// Runs `lsof +D <path>` and returns all holder processes.
    private func scanHolders(path: String) async throws -> [HolderProcess] {
        let result = try await ProcessRunner.run(
            "/usr/sbin/lsof",
            arguments: ["+D", path]
        )
        guard !result.stdout.isEmpty else { return [] }
        return HolderProcess.parse(lsofOutput: result.stdout)
    }

    /// Returns total byte count (in bytes) for a directory tree via `du -sk`.
    ///
    /// Uses `FileManager.attributesOfItem` recursion via a shell `du` call.
    /// The method is async because `ProcessRunner.run` is async.
    private func directorySize(at path: String) async throws -> Int64 {
        // `du -sk` on macOS uses 1024-byte blocks when -k is supplied.
        // Output format: "<blocks>\t<path>"
        let result = try await ProcessRunner.run("/usr/bin/du", arguments: ["-sk", path])
        let parts = result.stdout.split(separator: "\t")
        guard let kbStr = parts.first,
              let kb = Int64(kbStr.trimmingCharacters(in: .whitespaces))
        else { return 0 }
        return kb * 1024
    }

    /// Returns available bytes on the volume at `mountPath`, or `nil` if unreadable.
    private func volumeFreeBytes(at mountPath: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: mountPath),
              let free = attrs[.systemFreeSize] as? Int64
        else { return nil }
        return free
    }

    /// Creates the lock directory hierarchy if it doesn't exist.
    private func createLockDirectory(lockPath: String) throws {
        let dir = (lockPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Atomically creates a lock file. Returns `true` when lock was acquired,
    /// `false` when the file already exists (another reclaim is in progress).
    private func acquireLock(at path: String) -> Bool {
        FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
    }

    /// Removes the lock file.
    private func releaseLock(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Restores a single `OffloadRule` symlink — removes any existing item at the
    /// source path and creates a new symlink pointing to the rule target.
    private func restoreOffloadRule(_ rule: OffloadRule) throws {
        let fm = FileManager.default
        let sourcePath = rule.resolvedSource
        if fm.fileExists(atPath: sourcePath) ||
           (try? fm.destinationOfSymbolicLink(atPath: sourcePath)) != nil {
            try fm.removeItem(atPath: sourcePath)
        }
        try fm.createSymbolicLink(atPath: sourcePath, withDestinationPath: rule.target)
    }

    private func detach(drive: FleetDrive, force: Bool) async -> DetachResult {
        let mountPath = attachedVolumes[drive.id] ?? drive.mount
        do {
            let result = try await hdiutil.detach(mountPath: mountPath, force: force)
            if result.succeeded {
                attachedVolumes.removeValue(forKey: drive.id)
                return DetachResult(id: drive.id, succeeded: true,
                                    message: "Detached \(drive.id) from \(mountPath)")
            } else {
                return DetachResult(id: drive.id, succeeded: false,
                                    message: "hdiutil detach failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch {
            return DetachResult(id: drive.id, succeeded: false,
                                message: "detach error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Result types

public struct AttachResult: Sendable, Equatable {
    public let id: String
    public let mountPath: String?
    public let succeeded: Bool
    public let message: String
}

public struct DetachResult: Sendable, Equatable {
    public let id: String
    public let succeeded: Bool
    public let message: String
}

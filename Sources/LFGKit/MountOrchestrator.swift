import Foundation

// MARK: - Hdiutil abstraction

/// Abstraction over `hdiutil` attach/detach to enable test injection.
public protocol HdiutilInterface: Sendable {
    func attach(imagePath: String) async throws -> ProcessRunner.Result
    func detach(mountPath: String, force: Bool) async throws -> ProcessRunner.Result
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

    // MARK: Private helpers

    private func attach(drive: FleetDrive) async -> AttachResult {
        // Already attached — idempotent.
        if let mp = attachedVolumes[drive.id] {
            return AttachResult(id: drive.id, mountPath: mp, succeeded: true,
                                message: "Already attached at \(mp)")
        }

        let imagePath = drive.resolvedImagePath
        do {
            let result = try await hdiutil.attach(imagePath: imagePath)
            if result.succeeded {
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

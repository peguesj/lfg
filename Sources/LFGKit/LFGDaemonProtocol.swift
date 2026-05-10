import Foundation

// MARK: - XPC Protocol

/// XPC protocol for UI ↔ daemon IPC.
/// Service identifier: io.lfg.daemon
///
/// All reply closures are called exactly once on the XPC queue.
///
/// Example (client side):
/// ```swift
/// let conn = NSXPCConnection(serviceName: LFGDaemonServiceID)
/// conn.remoteObjectInterface = NSXPCInterface(with: LFGDaemonProtocol.self)
/// conn.resume()
/// let proxy = conn.remoteObjectProxy as! LFGDaemonProtocol
/// proxy.status { dict in print(dict) }
/// ```
@objc public protocol LFGDaemonProtocol {
    /// Returns a dictionary with current daemon status.
    /// Keys: uptime (Double), watcherActive (Bool), lastEventAt (Double?),
    ///       attachedVolumes ([String])
    func status(reply: @escaping ([String: Any]) -> Void)

    /// Manually attaches the named volume (fleet.json id, e.g. "901DEVLIB").
    func mountVolume(_ name: String, reply: @escaping (Bool, String) -> Void)

    /// Manually detaches the named volume.
    func unmountVolume(_ name: String, reply: @escaping (Bool, String) -> Void)

    /// Triggers a reconcile pass: verify all auto-policy volumes are in expected state.
    func reconcile(reply: @escaping (Bool, String) -> Void)

    /// Returns JSON-encoded ``FleetState``.
    func fleetState(reply: @escaping (Data) -> Void)

    /// Pauses automatic mount on next YJ_MORE appearance (manual-eject flag).
    func pauseAutoMount(reply: @escaping (Bool) -> Void)
}

/// Stable service name used by both daemon and client.
public let LFGDaemonServiceID = "io.lfg.daemon"

// MARK: - Shared Codable types

/// Status of a single tracked volume as reported by the daemon.
public struct VolumeRecord: Codable, Sendable, Equatable {
    public let id: String
    public let image: String
    public let mountPath: String
    public let host: String
    public var status: VolumeStatus
    public var lastSeen: Date?

    public init(
        id: String,
        image: String,
        mountPath: String,
        host: String,
        status: VolumeStatus,
        lastSeen: Date? = nil
    ) {
        self.id = id
        self.image = image
        self.mountPath = mountPath
        self.host = host
        self.status = status
        self.lastSeen = lastSeen
    }
}

/// Lifecycle status for a volume.
public enum VolumeStatus: String, Codable, Sendable {
    /// Sparseimage attached, mountpoint accessible.
    case mounted
    /// Sparseimage detached, host present.
    case detached
    /// Host drive not present.
    case hostAbsent
    /// Last attach/detach attempt failed.
    case error
}

/// Snapshot of the full fleet as known to the daemon.
public struct FleetState: Codable, Sendable {
    public let volumes: [VolumeRecord]
    public let generatedAt: Date

    public init(volumes: [VolumeRecord], generatedAt: Date = .now) {
        self.volumes = volumes
        self.generatedAt = generatedAt
    }
}

/// Daemon health snapshot.
public struct DaemonStatus: Codable, Sendable {
    public let uptime: TimeInterval
    public let watcherActive: Bool
    public let lastEventAt: Date?
    public let attachedVolumes: [String]

    public init(
        uptime: TimeInterval,
        watcherActive: Bool,
        lastEventAt: Date?,
        attachedVolumes: [String]
    ) {
        self.uptime = uptime
        self.watcherActive = watcherActive
        self.lastEventAt = lastEventAt
        self.attachedVolumes = attachedVolumes
    }
}

// MARK: - Debouncer

/// Thread-safe debounce wrapper used by ``VolumeEventWatcher``.
/// Fires `action` after `interval` seconds of silence.
public final class Debouncer: @unchecked Sendable {
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private var workItem: DispatchWorkItem?

    public init(interval: TimeInterval, queue: DispatchQueue = .main) {
        self.interval = interval
        self.queue = queue
    }

    /// Schedule `action`. Cancels any previously pending invocation.
    public func call(action: @escaping () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    /// Cancel any pending invocation without firing.
    public func cancel() {
        workItem?.cancel()
        workItem = nil
    }

    /// Whether a call is currently pending.
    public var hasPendingWork: Bool { workItem?.isCancelled == false }
}

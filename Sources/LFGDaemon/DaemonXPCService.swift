import Foundation
import LFGKit

/// XPC listener that exposes ``LFGDaemonProtocol`` to the `LFGApp` UI process.
///
/// Lifecycle: created once in `main.swift`, kept alive by the RunLoop.
/// Each inbound connection gets its own `DaemonXPCHandler` instance.
public final class DaemonXPCService: NSObject, NSXPCListenerDelegate {

    private let listener: NSXPCListener
    private let orchestrator: MountOrchestrator
    private let registry: FleetRegistry
    private let startTime: Date = .now

    public init(orchestrator: MountOrchestrator, registry: FleetRegistry) {
        self.orchestrator = orchestrator
        self.registry = registry
        self.listener = NSXPCListener(machServiceName: LFGDaemonServiceID)
        super.init()
        self.listener.delegate = self
    }

    /// Start accepting connections. Non-blocking — relies on the caller's RunLoop.
    public func start() {
        listener.resume()
        LFGLogger.info("DaemonXPCService: listening on \(LFGDaemonServiceID)")
    }

    // MARK: NSXPCListenerDelegate

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: LFGDaemonProtocol.self)
        connection.exportedObject = DaemonXPCHandler(
            orchestrator: orchestrator,
            registry: registry,
            startTime: startTime
        )
        connection.resume()
        return true
    }
}

// MARK: - Per-connection handler

/// Implements ``LFGDaemonProtocol`` on behalf of one connected client.
final class DaemonXPCHandler: NSObject, LFGDaemonProtocol {

    private let orchestrator: MountOrchestrator
    private let registry: FleetRegistry
    private let startTime: Date

    init(orchestrator: MountOrchestrator, registry: FleetRegistry, startTime: Date) {
        self.orchestrator = orchestrator
        self.registry = registry
        self.startTime = startTime
    }

    // MARK: LFGDaemonProtocol

    func status(reply: @escaping ([String: Any]) -> Void) {
        Task {
            let attached = await orchestrator.attachedIds
            let dict: [String: Any] = [
                "uptime": Date.now.timeIntervalSince(startTime),
                "watcherActive": true,
                "attachedVolumes": attached,
            ]
            reply(dict)
        }
    }

    func mountVolume(_ name: String, reply: @escaping (Bool, String) -> Void) {
        Task {
            let result = await orchestrator.attachById(name)
            reply(result.succeeded, result.message)
        }
    }

    func unmountVolume(_ name: String, reply: @escaping (Bool, String) -> Void) {
        Task {
            let result = await orchestrator.detachById(name, force: false)
            reply(result.succeeded, result.message)
        }
    }

    func reconcile(reply: @escaping (Bool, String) -> Void) {
        Task {
            // Walk all auto drives; attach any that aren't currently mounted.
            var messages: [String] = []
            var allOk = true
            for drive in registry.allDrives where drive.isAutoReconnect {
                // Only attempt if host volume is present on disk.
                let hostPresent = FileManager.default.fileExists(
                    atPath: "/Volumes/\(drive.host)"
                )
                guard hostPresent else { continue }

                let r = await orchestrator.attachById(drive.id)
                if !r.succeeded { allOk = false }
                messages.append(r.message)
            }
            reply(allOk, messages.joined(separator: "; "))
        }
    }

    func fleetState(reply: @escaping (Data) -> Void) {
        Task {
            let attached = await orchestrator.attachedIds
            let attachedSet = Set(attached)
            let records: [VolumeRecord] = registry.allDrives.map { drive in
                let status: VolumeStatus
                if attachedSet.contains(drive.id) {
                    status = .mounted
                } else if FileManager.default.fileExists(atPath: "/Volumes/\(drive.host)") {
                    status = .detached
                } else {
                    status = .hostAbsent
                }
                return VolumeRecord(
                    id: drive.id,
                    image: drive.image,
                    mountPath: drive.mount,
                    host: drive.host,
                    status: status
                )
            }
            let state = FleetState(volumes: records)
            let data = (try? JSONEncoder().encode(state)) ?? Data()
            reply(data)
        }
    }

    func pauseAutoMount(reply: @escaping (Bool) -> Void) {
        // Delegates to the shared watcher state via NotificationCenter.
        NotificationCenter.default.post(
            name: .lfgPauseAutoMount,
            object: nil
        )
        reply(true)
    }
}

// MARK: - Notification name

public extension Notification.Name {
    /// Posted when a client calls `pauseAutoMount`. The watcher observes this.
    static let lfgPauseAutoMount = Notification.Name("io.lfg.daemon.pauseAutoMount")
}

// MARK: - Minimal logger (no external deps)

enum LFGLogger {
    static func info(_ message: String) {
        var stderr = FileHandle.standardError
        let line = "[LFGDaemon] \(message)\n"
        stderr.write(Data(line.utf8))
    }
}

extension FileHandle: @retroactive TextOutputStream {
    public func write(_ string: String) {
        let data = Data(string.utf8)
        self.write(data)
    }
}

import Foundation

/// Polls disk usage via FileManager and updates AppState.
actor DiskMonitorService {
    private var timer: Timer?
    private let interval: TimeInterval

    init(interval: TimeInterval = 30.0) {
        self.interval = interval
    }

    func start(updating state: AppState) {
        state.updateDiskInfo()
        // Polling handled by caller via Task.sleep loop
    }

    func snapshot(volumePath: String = "/") -> (total: UInt64, free: UInt64)? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: volumePath) else {
            return nil
        }
        let total = (attrs[.systemSize] as? UInt64) ?? 0
        let free = (attrs[.systemFreeSize] as? UInt64) ?? 0
        return (total, free)
    }
}

import Foundation
import Observation

@Observable
final class AppState {
    var moduleStatuses: [LFGModule: ModuleStatus] = {
        var map: [LFGModule: ModuleStatus] = [:]
        for module in LFGModule.allCases {
            map[module] = ModuleStatus()
        }
        return map
    }()

    var selectedModule: LFGModule? = nil
    var totalDiskSpace: UInt64 = 0
    var freeDiskSpace: UInt64 = 0

    var usedDiskSpace: UInt64 {
        totalDiskSpace > freeDiskSpace ? totalDiskSpace - freeDiskSpace : 0
    }

    var diskUsagePercent: Double {
        guard totalDiskSpace > 0 else { return 0 }
        return Double(usedDiskSpace) / Double(totalDiskSpace) * 100.0
    }

    func updateDiskInfo() {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        ) else { return }
        totalDiskSpace = (attrs[.systemSize] as? UInt64) ?? 0
        freeDiskSpace = (attrs[.systemFreeSize] as? UInt64) ?? 0
    }
}

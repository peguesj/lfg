import Foundation

enum ModuleRunState: String, Codable {
    case idle
    case running
    case completed
    case error
}

struct ModuleStatus {
    var state: ModuleRunState = .idle
    var lastRun: Date? = nil
    var lastError: String? = nil
    var progress: Double = 0.0

    var isRunning: Bool { state == .running }
}

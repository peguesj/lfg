import Foundation
import SwiftData

@Model
final class DiskSnapshot {
    var timestamp: Date
    var totalBytes: UInt64
    var freeBytes: UInt64
    var volumeName: String

    var usedBytes: UInt64 {
        totalBytes > freeBytes ? totalBytes - freeBytes : 0
    }

    init(timestamp: Date = .now, totalBytes: UInt64, freeBytes: UInt64, volumeName: String) {
        self.timestamp = timestamp
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.volumeName = volumeName
    }
}

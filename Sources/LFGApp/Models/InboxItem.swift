import Foundation
import SwiftData

@Model
final class InboxItem {
    var path: String
    var sizeBytes: UInt64
    var detectedAt: Date
    var category: String
    var isResolved: Bool

    init(
        path: String,
        sizeBytes: UInt64 = 0,
        detectedAt: Date = .now,
        category: String = "unknown",
        isResolved: Bool = false
    ) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.detectedAt = detectedAt
        self.category = category
        self.isResolved = isResolved
    }
}

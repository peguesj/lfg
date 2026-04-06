import Foundation
import SwiftData

@Model
final class VolumeProfile {
    var name: String
    var mountPoint: String
    var fileSystemType: String
    var isRemovable: Bool
    var isInternal: Bool
    var lastSeen: Date

    init(
        name: String,
        mountPoint: String,
        fileSystemType: String = "APFS",
        isRemovable: Bool = false,
        isInternal: Bool = true,
        lastSeen: Date = .now
    ) {
        self.name = name
        self.mountPoint = mountPoint
        self.fileSystemType = fileSystemType
        self.isRemovable = isRemovable
        self.isInternal = isInternal
        self.lastSeen = lastSeen
    }
}

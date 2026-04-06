import Foundation
import LFGKit

struct ScanEntry: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let path: URL
    let sizeBytes: Int64
    let isDirectory: Bool

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct ScanResult: Sendable {
    let entries: [ScanEntry]
    let totalBytes: Int64
    let duration: TimeInterval
}

/// Native disk scanner using FileManager.enumerator with URLResourceKey for accurate sizes.
actor DiskMonitorService {
    /// Scan a directory and return top-level children with cumulative sizes.
    func scan(path: URL) async throws -> ScanResult {
        let start = CFAbsoluteTimeGetCurrent()
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue else {
            return ScanResult(entries: [], totalBytes: 0, duration: 0)
        }

        let children = (try? fm.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var entries: [ScanEntry] = []
        for child in children {
            try Task.checkCancellation()
            let size = Self.sizeOfItem(at: child, fm: fm)
            var childIsDir: ObjCBool = false
            fm.fileExists(atPath: child.path, isDirectory: &childIsDir)
            entries.append(ScanEntry(
                name: child.lastPathComponent,
                path: child,
                sizeBytes: size,
                isDirectory: childIsDir.boolValue
            ))
        }

        entries.sort { $0.sizeBytes > $1.sizeBytes }
        let total = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return ScanResult(entries: entries, totalBytes: total,
                          duration: CFAbsoluteTimeGetCurrent() - start)
    }

    /// APFS-accurate volume stats using volumeAvailableCapacityForImportantUsageKey.
    func volumeStats(path: String = "/") -> (total: Int64, free: Int64)? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(0)
        return (Int64(total), free)
    }

    private static func sizeOfItem(at url: URL, fm: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }

        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let v = try? fileURL.resourceValues(forKeys: keys)
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

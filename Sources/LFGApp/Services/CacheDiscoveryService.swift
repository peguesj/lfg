import Foundation

/// Discovers and manages reclaimable cache directories.
actor CacheDiscoveryService {
    enum CacheCategory: String, Sendable, CaseIterable {
        case system = "System"
        case build = "Build"
        case package = "Package"
        case temp = "Temp"
    }

    struct CacheTarget: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let path: URL
        let sizeBytes: Int64
        let category: CacheCategory

        var sizeFormatted: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    struct CleanResult: Sendable {
        let removedCount: Int
        let freedBytes: Int64
        let errors: [(String, String)]
    }

    private static let knownPaths: [(String, String, CacheCategory)] = [
        ("User Caches", "Library/Caches", .system),
        ("System Logs", "Library/Logs", .system),
        ("Xcode DerivedData", "Library/Developer/Xcode/DerivedData", .build),
        ("iOS Simulators", "Library/Developer/CoreSimulator/Devices", .build),
        ("SPM Cache", "Library/Developer/Xcode/SPM", .build),
        ("npm Cache", ".npm/_cacache", .package),
        ("Yarn Cache", "Library/Caches/Yarn", .package),
        ("pip Cache", "Library/Caches/pip", .package),
        ("CocoaPods", "Library/Caches/CocoaPods", .package),
        ("Homebrew", "Library/Caches/Homebrew", .package),
        ("Gradle", ".gradle/caches", .package),
        ("Go Modules", "go/pkg/mod/cache", .package),
        ("Cargo", ".cargo/registry", .package),
    ]

    func discover() async -> [CacheTarget] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var results: [CacheTarget] = []

        for (name, rel, cat) in Self.knownPaths {
            let url = home.appendingPathComponent(rel)
            guard fm.fileExists(atPath: url.path) else { continue }
            let size = Self.dirSize(url, fm)
            guard size > 1024 else { continue }
            results.append(CacheTarget(name: name, path: url, sizeBytes: size, category: cat))
        }

        // System temp
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let tmpSize = Self.dirSize(tmp, fm)
        if tmpSize > 1024 {
            results.append(CacheTarget(name: "System Temp", path: tmp, sizeBytes: tmpSize, category: .temp))
        }

        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    func clean(targets: [CacheTarget]) async -> CleanResult {
        let fm = FileManager.default
        var removed = 0; var freed: Int64 = 0; var errors: [(String, String)] = []
        for t in targets {
            guard let contents = try? fm.contentsOfDirectory(at: t.path, includingPropertiesForKeys: nil) else {
                errors.append((t.name, "Cannot list contents")); continue
            }
            for item in contents {
                do {
                    let sz = Self.dirSize(item, fm)
                    try fm.removeItem(at: item)
                    freed += sz; removed += 1
                } catch { errors.append((t.name, error.localizedDescription)) }
            }
        }
        return CleanResult(removedCount: removed, freedBytes: freed, errors: errors)
    }

    private static func dirSize(_ url: URL, _ fm: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                     options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: keys)
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

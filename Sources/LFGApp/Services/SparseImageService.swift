import Foundation
import LFGKit

/// Discovers and manages sparse disk images for backups.
actor SparseImageService {
    struct ImageEntry: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let path: URL
        let sizeBytes: Int64
        let isMounted: Bool
        let mountPoint: String?

        var sizeFormatted: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    func discover(searchPaths: [URL]) async -> [ImageEntry] {
        let fm = FileManager.default
        let exts: Set<String> = ["sparseimage", "sparsebundle"]
        var found: [URL] = []

        for root in searchPaths {
            guard fm.fileExists(atPath: root.path),
                  let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles], errorHandler: { _, _ in true })
            else { continue }
            for case let url as URL in e {
                if e.level > 3 { e.skipDescendants(); continue }
                if exts.contains(url.pathExtension.lowercased()) {
                    found.append(url)
                    if url.pathExtension.lowercased() == "sparsebundle" { e.skipDescendants() }
                }
            }
        }

        let mounted = await getMountMap()
        return found.map { url in
            let size = Self.itemSize(url, fm)
            let mp = mounted[url.path]
            return ImageEntry(name: url.lastPathComponent, path: url, sizeBytes: size,
                              isMounted: mp != nil, mountPoint: mp)
        }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    func mount(_ image: ImageEntry) async throws {
        let r = try await ProcessRunner.run("/usr/bin/hdiutil", arguments: ["attach", image.path.path, "-nobrowse"])
        guard r.exitCode == 0 else { throw ImageError.mountFailed(image.name, r.stderr) }
    }

    func unmount(_ image: ImageEntry) async throws {
        let target = image.mountPoint ?? image.path.path
        let r = try await ProcessRunner.run("/usr/bin/hdiutil", arguments: ["detach", target])
        guard r.exitCode == 0 else {
            let r2 = try await ProcessRunner.run("/usr/bin/hdiutil", arguments: ["detach", target, "-force"])
            guard r2.exitCode == 0 else { throw ImageError.unmountFailed(image.name, r2.stderr) }
            return
        }
    }

    private func getMountMap() async -> [String: String] {
        guard let r = try? await ProcessRunner.run("/usr/bin/hdiutil", arguments: ["info", "-plist"]),
              r.exitCode == 0,
              let data = r.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [:] }
        var map: [String: String] = [:]
        for img in images {
            guard let path = img["image-path"] as? String,
                  let entities = img["system-entities"] as? [[String: Any]] else { continue }
            for e in entities {
                if let mp = e["mount-point"] as? String { map[path] = mp; break }
            }
        }
        return map
    }

    private static func itemSize(_ url: URL, _ fm: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                     options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: keys)
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }

    enum ImageError: Error, LocalizedError {
        case mountFailed(String, String), unmountFailed(String, String)
        var errorDescription: String? {
            switch self {
            case .mountFailed(let n, let d): return "Mount '\(n)' failed: \(d)"
            case .unmountFailed(let n, let d): return "Unmount '\(n)' failed: \(d)"
            }
        }
    }
}

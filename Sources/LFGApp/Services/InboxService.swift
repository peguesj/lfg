import Foundation

/// Monitors directories for new large files using periodic scanning.
/// FSEvents integration planned for future iteration.
actor InboxService {
    private let watchPaths: [String]
    private let thresholdBytes: UInt64

    init(
        watchPaths: [String] = ["~/Downloads", "~/Desktop"],
        thresholdBytes: UInt64 = 100 * 1024 * 1024 // 100 MB
    ) {
        self.watchPaths = watchPaths.map {
            NSString(string: $0).expandingTildeInPath
        }
        self.thresholdBytes = thresholdBytes
    }

    func scan() -> [InboxCandidate] {
        var candidates: [InboxCandidate] = []
        let fm = FileManager.default

        for dir in watchPaths {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                      values.isDirectory != true,
                      let size = values.fileSize,
                      UInt64(size) >= thresholdBytes else { continue }

                candidates.append(InboxCandidate(
                    path: url.path,
                    sizeBytes: UInt64(size)
                ))
            }
        }
        return candidates
    }
}

struct InboxCandidate {
    let path: String
    let sizeBytes: UInt64
}

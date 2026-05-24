import Foundation

// MARK: - MountedVolume

/// A currently-mounted volume discovered via FileManager APIs.
///
/// `DiskScanner.scan()` returns one entry per mounted volume visible to the current
/// user. Internal system volumes (e.g. `/System/Volumes/*`) are excluded by default.
public struct MountedVolume: Identifiable, Sendable, Equatable, Hashable {

    // MARK: Properties

    /// Stable identifier — the canonical mount path.
    public let id: String

    /// Volume label as shown in Finder (e.g. `"YJ_MORE"`, `"Macintosh HD"`).
    public let name: String

    /// Absolute path where the volume is mounted (e.g. `"/Volumes/YJ_MORE"`).
    public let mountPoint: String

    /// Total capacity in bytes. `0` when unavailable.
    public let totalBytes: Int64

    /// Available free space in bytes. `0` when unavailable.
    public let freeBytes: Int64

    /// Whether the volume is on removable media.
    public let isRemovable: Bool

    /// Localised file-system description (e.g. `"APFS"`, `"ExFAT"`).
    public let fileSystemType: String

    // MARK: Derived

    public var totalGB: Double   { Double(totalBytes) / 1_073_741_824 }
    public var freeGB: Double    { Double(freeBytes)  / 1_073_741_824 }
    public var usedGB: Double    { max(0, totalGB - freeGB) }

    /// 0.0 … 1.0 fill ratio; `0` when `totalBytes` is unknown.
    public var usageRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - freeBytes) / Double(totalBytes)
    }
}

// MARK: - DiskScanner

/// Scans currently-mounted volumes using `FileManager` resource values.
///
/// No subprocess is required — all data comes from the native FS API.
/// Inject `DiskScanner.scan(using:)` with a custom URL provider in tests.
public enum DiskScanner {

    // MARK: Production entry point

    /// Returns all non-hidden mounted volumes.
    public static func scan() -> [MountedVolume] {
        scan(urlProvider: { keys in
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys,
                options: []
            )
        })
    }

    // MARK: Testable core

    /// Scan using an injectable URL provider — enables unit testing without live disk access.
    ///
    /// - Parameter urlProvider: Called with the required `URLResourceKey` set; should return
    ///   all candidate volume URLs (or `nil` to indicate an error).
    public static func scan(
        urlProvider: ([URLResourceKey]) -> [URL]?
    ) -> [MountedVolume] {

        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsInternalKey
        ]

        guard let urls = urlProvider(keys) else { return [] }

        return urls.compactMap { url -> MountedVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }

            // Skip macOS system-internal sub-volumes by mount path prefix.
            let mp = url.path
            if mp.hasPrefix("/System/Volumes/") { return nil }

            let name        = values.volumeName ?? url.lastPathComponent
            let total       = Int64(values.volumeTotalCapacity ?? 0)
            let free        = Int64(values.volumeAvailableCapacity ?? 0)
            let removable   = values.volumeIsRemovable ?? false
            let fsType      = values.volumeLocalizedFormatDescription ?? "Unknown"

            return MountedVolume(
                id:             mp,
                name:           name,
                mountPoint:     mp,
                totalBytes:     total,
                freeBytes:      free,
                isRemovable:    removable,
                fileSystemType: fsType
            )
        }
        .sorted { $0.mountPoint < $1.mountPoint }
    }
}

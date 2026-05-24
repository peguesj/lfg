import XCTest
@testable import LFGKit

final class DiskScannerTests: XCTestCase {

    // MARK: - MountedVolume properties

    func testMountedVolumeGBConversions() {
        let vol = MountedVolume(
            id: "/Volumes/TEST",
            name: "TEST",
            mountPoint: "/Volumes/TEST",
            totalBytes: 107_374_182_400,   // 100 GB
            freeBytes:  32_212_254_720,    //  30 GB
            isRemovable: true,
            fileSystemType: "APFS"
        )
        XCTAssertEqual(vol.totalGB, 100.0, accuracy: 0.01)
        XCTAssertEqual(vol.freeGB,   30.0, accuracy: 0.01)
        XCTAssertEqual(vol.usedGB,   70.0, accuracy: 0.01)
    }

    func testUsageRatioCalculation() {
        let vol = MountedVolume(
            id: "/Volumes/X",
            name: "X",
            mountPoint: "/Volumes/X",
            totalBytes: 200,
            freeBytes: 50,
            isRemovable: false,
            fileSystemType: "APFS"
        )
        XCTAssertEqual(vol.usageRatio, 0.75, accuracy: 0.001)
    }

    func testUsageRatioZeroWhenTotalUnknown() {
        let vol = MountedVolume(
            id: "/", name: "/", mountPoint: "/",
            totalBytes: 0, freeBytes: 0,
            isRemovable: false, fileSystemType: "APFS"
        )
        XCTAssertEqual(vol.usageRatio, 0)
    }

    func testMountedVolumeIdentifiable() {
        let vol = MountedVolume(
            id: "/Volumes/FOO", name: "FOO", mountPoint: "/Volumes/FOO",
            totalBytes: 1000, freeBytes: 500,
            isRemovable: true, fileSystemType: "ExFAT"
        )
        XCTAssertEqual(vol.id, "/Volumes/FOO")
    }

    // MARK: - DiskScanner.scan(urlProvider:)

    func testScanFiltersSystemVolumePaths() {
        let fakeURLs: [URL] = [
            URL(fileURLWithPath: "/System/Volumes/Data"),
            URL(fileURLWithPath: "/Volumes/YJ_MORE"),
        ]
        let results = DiskScanner.scan { _ in fakeURLs }
        // /System/Volumes/Data is filtered; /Volumes/YJ_MORE passes through
        // (resource values will be empty → compactMap drops it too, so result may be 0 or 1)
        let paths = results.map(\.mountPoint)
        XCTAssertFalse(paths.contains("/System/Volumes/Data"))
    }

    func testScanReturnsEmptyOnNilProvider() {
        let results = DiskScanner.scan { _ in nil }
        XCTAssertTrue(results.isEmpty)
    }

    func testScanResultsSortedByMountPoint() {
        // Provide real filesystem root URLs whose resource values will succeed.
        let urls = [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/")]
        let results = DiskScanner.scan { _ in urls }
        let paths = results.map(\.mountPoint)
        XCTAssertEqual(paths, paths.sorted())
    }

    // MARK: - Hashable / Equatable

    func testMountedVolumeHashable() {
        let a = MountedVolume(id: "/Volumes/A", name: "A", mountPoint: "/Volumes/A",
                              totalBytes: 1000, freeBytes: 500, isRemovable: false, fileSystemType: "APFS")
        let b = MountedVolume(id: "/Volumes/A", name: "A", mountPoint: "/Volumes/A",
                              totalBytes: 1000, freeBytes: 500, isRemovable: false, fileSystemType: "APFS")
        XCTAssertEqual(a, b)
        var set = Set<MountedVolume>()
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1)
    }
}

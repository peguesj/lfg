import XCTest
@testable import LFGKit

@MainActor
final class DesignTokenTests: XCTestCase {
    func testWTFSViewModelInitialState() {
        let vm = WTFSViewModel(runner: MockShellRunner(result: .init(exitCode: 0, stdout: "", stderr: "")))
        XCTAssertEqual(vm.output, "")
        XCTAssertFalse(vm.isScanning)
        XCTAssertNil(vm.error)
    }

    func testDTFViewModelInitialState() {
        let vm = DTFViewModel(runner: MockShellRunner(result: .init(exitCode: 0, stdout: "", stderr: "")))
        XCTAssertTrue(vm.caches.isEmpty)
        XCTAssertFalse(vm.isDiscovering)
    }

    func testSSDViewModelInitialState() {
        let vm = SSDViewModel(runner: MockShellRunner(result: .init(exitCode: 0, stdout: "0", stderr: "")))
        XCTAssertTrue(vm.indexedVolumes.isEmpty)
        XCTAssertEqual(vm.cpuPercent, 0)
    }

    func testCacheItemIdentity() {
        let a = CacheItem(name: "npm", path: "~/.npm", size: "1G")
        let b = CacheItem(name: "npm", path: "~/.npm", size: "1G")
        XCTAssertNotEqual(a.id, b.id)
    }
}

import XCTest
@testable import LFGKit

@MainActor
final class DTFViewModelTests: XCTestCase {
    func testDiscoverParsesCaches() async {
        let output = "1.2G\t/Users/test/.npm-cache\n500M\t/Users/test/.gradle"
        let mock = MockShellRunner(result: .init(exitCode: 0, stdout: output, stderr: ""))
        let vm = DTFViewModel(runner: mock)
        await vm.discover()
        XCTAssertEqual(vm.caches.count, 2)
        XCTAssertEqual(vm.caches[0].name, ".npm-cache")
        XCTAssertEqual(vm.caches[0].size, "1.2G")
        XCTAssertFalse(vm.isDiscovering)
    }

    func testDiscoverIgnoresMalformedLines() async {
        let output = "bad line\n\t\n1G\t/tmp/cache"
        let mock = MockShellRunner(result: .init(exitCode: 0, stdout: output, stderr: ""))
        let vm = DTFViewModel(runner: mock)
        await vm.discover()
        XCTAssertEqual(vm.caches.count, 1)
    }

    func testCleanRemovesItem() async {
        let output = "1.2G\t/tmp/cache"
        let mock = MockShellRunner(result: .init(exitCode: 0, stdout: output, stderr: ""))
        let vm = DTFViewModel(runner: mock)
        await vm.discover()
        XCTAssertEqual(vm.caches.count, 1)
        let item = vm.caches[0]
        await vm.clean(item)
        XCTAssertTrue(vm.caches.isEmpty)
    }
}

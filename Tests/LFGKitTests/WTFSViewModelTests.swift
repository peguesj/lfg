import XCTest
@testable import LFGKit

final class MockShellRunner: ShellRunnerProtocol, @unchecked Sendable {
    private let result: ProcessRunner.Result
    private let lock = NSLock()
    private var _commands: [String] = []

    var lastCommand: String { lock.withLock { _commands.last ?? "" } }
    var allCommands: [String] { lock.withLock { _commands } }

    init(result: ProcessRunner.Result) {
        self.result = result
    }

    func shell(_ command: String) async throws -> ProcessRunner.Result {
        lock.withLock { _commands.append(command) }
        return result
    }
}

@MainActor
final class WTFSViewModelTests: XCTestCase {
    func testScanSetsOutput() async {
        let mock = MockShellRunner(result: .init(exitCode: 0, stdout: "1.2G\t/tmp", stderr: ""))
        let vm = WTFSViewModel(runner: mock)
        await vm.scan(path: "/tmp")
        XCTAssertEqual(vm.output, "1.2G\t/tmp")
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isScanning)
    }

    func testScanSetsErrorOnFailure() async {
        let mock = MockShellRunner(result: .init(exitCode: 1, stdout: "", stderr: "permission denied"))
        let vm = WTFSViewModel(runner: mock)
        await vm.scan(path: "/tmp")
        XCTAssertEqual(vm.error, "permission denied")
        XCTAssertEqual(vm.output, "")
    }

    func testScanNotRunnningAfterCompletion() async {
        let mock = MockShellRunner(result: .init(exitCode: 0, stdout: "ok", stderr: ""))
        let vm = WTFSViewModel(runner: mock)
        await vm.scan(path: "/tmp")
        XCTAssertFalse(vm.isScanning)
    }
}

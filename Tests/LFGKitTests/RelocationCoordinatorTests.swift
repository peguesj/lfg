import XCTest
@testable import LFGKit

// MARK: - Mock shell runner for RelocationCoordinator

private final class MockRelocationShellRunner: ShellRunnerProtocol {
    struct Call {
        let command: String
    }
    var calls: [Call] = []
    var results: [String: ProcessRunner.Result] = [:]
    var defaultResult = ProcessRunner.Result(exitCode: 0, stdout: "", stderr: "")

    func shell(_ command: String) async throws -> ProcessRunner.Result {
        calls.append(Call(command: command))
        for (key, result) in results where command.contains(key) {
            return result
        }
        return defaultResult
    }
}

// MARK: - RelocationCoordinatorTests

@MainActor
final class RelocationCoordinatorTests: XCTestCase {

    private func tempFleetURL(drives: [[String: Any]] = []) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-fleet.json")
        let obj: [String: Any] = ["drives": drives, "external_hosts": []]
        try JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted).write(to: url)
        return url
    }

    private func makeBackend() -> VolumeBackend {
        let json = """
        {
          "id": "901DEVLIB",
          "image": "/tmp/test-901.dmg.sparseimage",
          "mount": "/Volumes/DDRV-901",
          "host": "YJ_MORE",
          "reconnect_policy": "auto",
          "symlinks": []
        }
        """
        return try! JSONDecoder().decode(VolumeBackend.self, from: json.data(using: .utf8)!)
    }

    // MARK: - Phase progression

    func testInitialPhaseIsIdle() {
        let coordinator = RelocationCoordinator()
        if case .idle = coordinator.phase { } else {
            XCTFail("Expected .idle, got \(coordinator.phase)")
        }
    }

    func testResetRestoresIdlePhase() {
        let coordinator = RelocationCoordinator()
        coordinator.reset()
        if case .idle = coordinator.phase { } else {
            XCTFail("Expected .idle after reset")
        }
        XCTAssertEqual(coordinator.statusMessage, "")
    }

    // MARK: - Preflight: source not found

    func testRelocateFailsWhenSourceMissing() async throws {
        let backend = makeBackend()   // image path /tmp/test-901… does not exist
        let url = try tempFleetURL(drives: [
            ["id": "901DEVLIB", "image": "/tmp/test-901.dmg.sparseimage",
             "mount": "/Volumes/DDRV-901", "host": "YJ_MORE",
             "reconnect_policy": "auto", "symlinks": []]
        ])
        let coordinator = RelocationCoordinator()
        await coordinator.relocate(backend: backend, destinationDirectory: "/tmp", fleetURL: url)
        if case .failed(let msg) = coordinator.phase {
            XCTAssertTrue(msg.contains("not found") || msg.contains("exist"))
        } else {
            XCTFail("Expected .failed, got \(coordinator.phase)")
        }
    }

    // MARK: - RelocationPhase equatable

    func testPhaseEquatableIdle() {
        XCTAssertEqual(RelocationPhase.idle, RelocationPhase.idle)
    }

    func testPhaseEquatableComplete() {
        XCTAssertEqual(RelocationPhase.complete, RelocationPhase.complete)
    }

    func testPhaseEquatableCopying() {
        XCTAssertEqual(RelocationPhase.copying(progress: 0.5), RelocationPhase.copying(progress: 0.5))
        XCTAssertNotEqual(RelocationPhase.copying(progress: 0.5), RelocationPhase.copying(progress: 0.9))
    }
}

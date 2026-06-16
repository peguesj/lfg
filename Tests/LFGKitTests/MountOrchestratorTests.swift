import XCTest
@testable import LFGKit

// MARK: - Mock hdiutil

/// Captures invocations and returns configurable results.
final class MockHdiutil: HdiutilInterface, @unchecked Sendable {
    enum Call: Equatable {
        case attach(imagePath: String)
        case detach(mountPath: String, force: Bool)
    }

    var calls: [Call] = []
    /// Return value for the next attach call. Defaults to success.
    var attachResult: ProcessRunner.Result = .init(exitCode: 0, stdout: "", stderr: "")
    /// Return value for the next detach call.
    var detachResult: ProcessRunner.Result = .init(exitCode: 0, stdout: "", stderr: "")
    /// If true, throw instead of returning a result.
    var shouldThrow = false

    func attach(imagePath: String) async throws -> ProcessRunner.Result {
        calls.append(.attach(imagePath: imagePath))
        if shouldThrow { throw NSError(domain: "mock", code: 1) }
        return attachResult
    }

    func detach(mountPath: String, force: Bool) async throws -> ProcessRunner.Result {
        calls.append(.detach(mountPath: mountPath, force: force))
        if shouldThrow { throw NSError(domain: "mock", code: 2) }
        return detachResult
    }

    func detachDevice(_ devNode: String, force: Bool) async throws -> ProcessRunner.Result {
        // Stub: returns success (empty plist means no stale device found).
        return .init(exitCode: 0, stdout: "", stderr: "")
    }

    func info() async throws -> ProcessRunner.Result {
        // Stub: returns empty plist (no images currently attached).
        return .init(exitCode: 0, stdout: "", stderr: "")
    }
}

// MARK: - Fleet fixtures

private let twoAutoOnYJ = """
{
  "version": "2.0",
  "drives": [
    {
      "id": "901DEVLIB",
      "image": "/Volumes/YJ_MORE/DevDrive/901DEVLIB.dmg.sparseimage",
      "mount": "/Volumes/DDRV-901-DEVLIB",
      "host": "YJ_MORE",
      "reconnect_policy": "auto"
    },
    {
      "id": "904MEMVT",
      "image": "/Volumes/YJ_MORE/DevDrive/904MEMVT-v2.dmg.sparseimage",
      "mount": "/Volumes/DDRV-904-MEMVT-v2",
      "host": "YJ_MORE",
      "reconnect_policy": "auto"
    }
  ]
}
""".data(using: .utf8)!

private let oneManualOnYJ = """
{
  "version": "2.0",
  "drives": [
    {
      "id": "manual-vol",
      "image": "/Volumes/YJ_MORE/DevDrive/manual.sparseimage",
      "mount": "/Volumes/MANUAL",
      "host": "YJ_MORE",
      "reconnect_policy": "manual"
    }
  ]
}
""".data(using: .utf8)!

// MARK: - Tests

final class MountOrchestratorTests: XCTestCase {

    // MARK: attachAll

    func testAttachAllInvokesHdiutilForEachAutoDrive() async throws {
        let reg = try FleetRegistry(jsonData: twoAutoOnYJ)
        let mock = MockHdiutil()
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        let results = await orc.attachAll(forHost: "YJ_MORE")

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy(\.succeeded))
        // Both attach calls should have been made.
        let attachCalls = mock.calls.filter {
            if case .attach = $0 { return true }
            return false
        }
        XCTAssertEqual(attachCalls.count, 2)
    }

    func testAttachAllSkipsManualPolicy() async throws {
        let reg = try FleetRegistry(jsonData: oneManualOnYJ)
        let mock = MockHdiutil()
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        let results = await orc.attachAll(forHost: "YJ_MORE")

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(mock.calls.isEmpty)
    }

    func testAttachAllFailureReportedInResult() async throws {
        let reg = try FleetRegistry(jsonData: twoAutoOnYJ)
        let mock = MockHdiutil()
        mock.attachResult = .init(exitCode: 1, stdout: "", stderr: "permission denied")
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        let results = await orc.attachAll(forHost: "YJ_MORE")

        XCTAssertTrue(results.allSatisfy { !$0.succeeded })
    }

    func testAttachAllThrowingHdiutilReportedAsFailure() async throws {
        let reg = try FleetRegistry(jsonData: twoAutoOnYJ)
        let mock = MockHdiutil()
        mock.shouldThrow = true
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        let results = await orc.attachAll(forHost: "YJ_MORE")

        XCTAssertTrue(results.allSatisfy { !$0.succeeded })
    }

    // MARK: Idempotent attach

    func testAttachSameDriveTwiceCallsHdiutilOnce() async throws {
        let reg = try FleetRegistry(jsonData: twoAutoOnYJ)
        let mock = MockHdiutil()
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        _ = await orc.attachById("901DEVLIB")
        _ = await orc.attachById("901DEVLIB")  // second call — should be idempotent

        let attachCalls = mock.calls.filter {
            if case .attach(let path) = $0 { return path.contains("901") }
            return false
        }
        XCTAssertEqual(attachCalls.count, 1, "hdiutil attach should only be called once per volume")
    }

    // MARK: detachAll

    func testDetachAllInvokesHdiutilForMountedVolumes() async throws {
        let reg = try FleetRegistry(jsonData: twoAutoOnYJ)
        let mock = MockHdiutil()
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        // Attach first so they appear in attachedIds.
        _ = await orc.attachAll(forHost: "YJ_MORE")
        mock.calls.removeAll()

        let results = await orc.detachAll(forHost: "YJ_MORE")

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy(\.succeeded))
        let detachCalls = mock.calls.filter {
            if case .detach = $0 { return true }
            return false
        }
        XCTAssertEqual(detachCalls.count, 2)
    }

    func testDetachAllSkipsUnattachedVolumes() async throws {
        let reg = try FleetRegistry(jsonData: twoAutoOnYJ)
        let mock = MockHdiutil()
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        // Don't attach anything first.
        let results = await orc.detachAll(forHost: "YJ_MORE")

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(mock.calls.isEmpty)
    }

    // MARK: attachById / detachById unknown id

    func testAttachByIdUnknownReturnsFailure() async throws {
        let reg = try FleetRegistry(jsonData: twoAutoOnYJ)
        let orc = MountOrchestrator(registry: reg, hdiutil: MockHdiutil())

        let result = await orc.attachById("PHANTOM")

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("not found"))
    }

    func testDetachByIdUnknownReturnsFailure() async throws {
        let reg = try FleetRegistry(jsonData: twoAutoOnYJ)
        let orc = MountOrchestrator(registry: reg, hdiutil: MockHdiutil())

        let result = await orc.detachById("PHANTOM")

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.message.contains("not found"))
    }

    // MARK: attachedIds tracking

    func testAttachedIdsUpdatedAfterSuccessfulAttach() async throws {
        let reg = try FleetRegistry(jsonData: twoAutoOnYJ)
        let orc = MountOrchestrator(registry: reg, hdiutil: MockHdiutil())

        _ = await orc.attachById("901DEVLIB")

        let ids = await orc.attachedIds
        XCTAssertTrue(ids.contains("901DEVLIB"))
    }

    func testAttachedIdsRemovedAfterDetach() async throws {
        let reg = try FleetRegistry(jsonData: twoAutoOnYJ)
        let orc = MountOrchestrator(registry: reg, hdiutil: MockHdiutil())

        _ = await orc.attachById("901DEVLIB")
        _ = await orc.detachById("901DEVLIB")

        let ids = await orc.attachedIds
        XCTAssertFalse(ids.contains("901DEVLIB"))
    }

    // MARK: CP-108 — no symlink/fallback touches

    /// The orchestrator must ONLY call hdiutil; it must not access known
    /// home-dir offload paths that are managed as symlinks.
    func testOrchestratorDoesNotTouchHomeDirOffloadPaths() async throws {
        let reg = try FleetRegistry(jsonData: twoAutoOnYJ)
        let mock = MockHdiutil()
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        _ = await orc.attachAll(forHost: "YJ_MORE")

        // Verify all attach calls use the sparseimage path, not any home-dir path.
        let forbiddenPrefixes = [
            NSHomeDirectory() + "/.npm-cache",
            NSHomeDirectory() + "/.vscode",
            NSHomeDirectory() + "/.asdf",
            NSHomeDirectory() + "/.lmstudio",
            NSHomeDirectory() + "/.continue",
            NSHomeDirectory() + "/.azurelogicapps",
        ]
        for call in mock.calls {
            if case .attach(let path) = call {
                for forbidden in forbiddenPrefixes {
                    XCTAssertFalse(
                        path.hasPrefix(forbidden),
                        "Orchestrator must not touch offload path \(forbidden)"
                    )
                }
            }
        }
    }
}

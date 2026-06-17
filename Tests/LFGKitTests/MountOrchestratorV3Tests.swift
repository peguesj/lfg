import XCTest
@testable import LFGKit

// MARK: - Mock (file-local; mirrors MockHdiutil in MountOrchestratorTests.swift)

private final class V3MockHdiutil: HdiutilInterface, @unchecked Sendable {
    enum Call: Equatable {
        case attach(imagePath: String)
        case detach(mountPath: String, force: Bool)
    }

    var calls: [Call] = []
    var attachResult: ProcessRunner.Result = .init(exitCode: 0, stdout: "", stderr: "")
    var detachResult: ProcessRunner.Result = .init(exitCode: 0, stdout: "", stderr: "")
    var shouldThrow = false

    func attach(imagePath: String) async throws -> ProcessRunner.Result {
        calls.append(.attach(imagePath: imagePath))
        if shouldThrow { throw NSError(domain: "v3mock", code: 1) }
        return attachResult
    }

    func detach(mountPath: String, force: Bool) async throws -> ProcessRunner.Result {
        calls.append(.detach(mountPath: mountPath, force: force))
        if shouldThrow { throw NSError(domain: "v3mock", code: 2) }
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

// MARK: - Fixtures

/// Two auto backends on YJ_MORE (900HOOKS + 901DEVLIB) plus one manual on internal.
/// Valid for both the v2 FleetDrive API and the v3 VolumeBackend API.
private let v3FixtureJSON = """
{
  "version": "2.0",
  "external_hosts": [
    {
      "name": "YJ_MORE",
      "mount": "/Volumes/YJ_MORE",
      "role": "external_host",
      "available_gb": 179,
      "status": "active",
      "keep_awake": true
    }
  ],
  "drives": [
    {
      "id": "900HOOKS",
      "image": "/Volumes/YJ_MORE/DevDrive/DDRV-900-HOOKS.sparseimage",
      "mount": "/Volumes/DDRV-900-HOOKS",
      "host": "YJ_MORE",
      "tier": "cold",
      "purpose": "npm/python hook environments",
      "reconnect_policy": "auto"
    },
    {
      "id": "901DEVLIB",
      "image": "~/DevDrive/901DEVLIB.sparseimage",
      "mount": "/Volumes/DDRV-901-DEVLIB",
      "host": "YJ_MORE",
      "tier": "cold",
      "purpose": "Xcode DerivedData",
      "reconnect_policy": "auto",
      "symlinks": [
        "~/.npm-cache \u{2192} /Volumes/DDRV-901-DEVLIB/npm-cache",
        "~/.asdf \u{2192} /Volumes/DDRV-901-DEVLIB/asdf"
      ]
    },
    {
      "id": "902APMDR",
      "image": "/Internal/DDRV-902-APMDR.sparseimage",
      "mount": "/Volumes/DDRV-902-APMDR",
      "host": "internal",
      "tier": "always_internal",
      "reconnect_policy": "manual"
    }
  ]
}
""".data(using: .utf8)!

/// Host with no auto-reconnect drives.
private let noAutoJSON = """
{
  "version": "2.0",
  "drives": [
    {
      "id": "manual-only",
      "image": "/Volumes/YJ_MORE/manual.sparseimage",
      "mount": "/Volumes/MANUAL",
      "host": "YJ_MORE",
      "reconnect_policy": "manual"
    }
  ]
}
""".data(using: .utf8)!

// MARK: - Tests

final class MountOrchestratorV3Tests: XCTestCase {

    // MARK: attachAll — happy path

    func testAttachAllForYJMORECallsHdiutilTwice() async throws {
        let reg = try FleetRegistry(jsonData: v3FixtureJSON)
        let mock = V3MockHdiutil()
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        let results = await orc.attachAll(forHost: "YJ_MORE")

        let attachCalls = mock.calls.filter {
            if case .attach = $0 { return true }
            return false
        }
        XCTAssertEqual(attachCalls.count, 2,
            "attachAll should invoke hdiutil.attach once per auto backend on YJ_MORE")
        XCTAssertEqual(results.count, 2)
    }

    func testAttachAllResultsCountMatchesAutoBackendCount() async throws {
        let reg = try FleetRegistry(jsonData: v3FixtureJSON)
        let mock = V3MockHdiutil()
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        let results = await orc.attachAll(forHost: "YJ_MORE")

        XCTAssertEqual(results.count, reg.autoBackends(forHost: "YJ_MORE").count)
    }

    // MARK: Idempotency

    func testAttachAllTwiceIsIdempotent() async throws {
        let reg = try FleetRegistry(jsonData: v3FixtureJSON)
        let mock = V3MockHdiutil()
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        _ = await orc.attachAll(forHost: "YJ_MORE")
        let callCountAfterFirst = mock.calls.count

        // Second call — already attached, should not issue new hdiutil calls.
        _ = await orc.attachAll(forHost: "YJ_MORE")
        let callCountAfterSecond = mock.calls.count

        XCTAssertEqual(callCountAfterFirst, callCountAfterSecond,
            "Second attachAll must not issue new hdiutil calls for already-attached volumes")
    }

    // MARK: Success result shape

    func testAttachAllSucceededTrueWhenHdiutilReturnsExitCodeZero() async throws {
        let reg = try FleetRegistry(jsonData: v3FixtureJSON)
        let mock = V3MockHdiutil()
        mock.attachResult = .init(exitCode: 0, stdout: "", stderr: "")
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        let results = await orc.attachAll(forHost: "YJ_MORE")

        XCTAssertTrue(results.allSatisfy(\.succeeded))
    }

    // MARK: Failure result shape

    func testAttachAllSucceededFalseWhenHdiutilReturnsNonZeroExitCode() async throws {
        let reg = try FleetRegistry(jsonData: v3FixtureJSON)
        let mock = V3MockHdiutil()
        mock.attachResult = .init(exitCode: 1, stdout: "", stderr: "disk image in use")
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        let results = await orc.attachAll(forHost: "YJ_MORE")

        XCTAssertTrue(results.allSatisfy { !$0.succeeded },
            "All results must report failure when hdiutil exits with a non-zero code")
    }

    func testAttachAllSucceededFalseWhenHdiutilThrows() async throws {
        let reg = try FleetRegistry(jsonData: v3FixtureJSON)
        let mock = V3MockHdiutil()
        mock.shouldThrow = true
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        let results = await orc.attachAll(forHost: "YJ_MORE")

        XCTAssertTrue(results.allSatisfy { !$0.succeeded },
            "All results must report failure when hdiutil throws")
    }

    // MARK: attachedIds tracking

    func testAttachedIdsReflectsSuccessfullyAttachedVolumes() async throws {
        let reg = try FleetRegistry(jsonData: v3FixtureJSON)
        let orc = MountOrchestrator(registry: reg, hdiutil: V3MockHdiutil())

        _ = await orc.attachAll(forHost: "YJ_MORE")

        let ids = await orc.attachedIds
        XCTAssertTrue(ids.contains("900HOOKS"))
        XCTAssertTrue(ids.contains("901DEVLIB"))
    }

    func testAttachedIdsDoesNotIncludeFailedVolumes() async throws {
        let reg = try FleetRegistry(jsonData: v3FixtureJSON)
        let mock = V3MockHdiutil()
        mock.attachResult = .init(exitCode: 1, stdout: "", stderr: "error")
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        _ = await orc.attachAll(forHost: "YJ_MORE")

        let ids = await orc.attachedIds
        XCTAssertTrue(ids.isEmpty, "attachedIds must be empty when all attaches failed")
    }

    // MARK: Host with no auto backends

    func testAttachAllForHostWithNoAutoBackendsReturnsEmptyArray() async throws {
        let reg = try FleetRegistry(jsonData: noAutoJSON)
        let mock = V3MockHdiutil()
        let orc = MountOrchestrator(registry: reg, hdiutil: mock)

        let results = await orc.attachAll(forHost: "YJ_MORE")

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(mock.calls.isEmpty, "No hdiutil calls should be made when there are no auto backends")
    }
}

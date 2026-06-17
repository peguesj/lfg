import XCTest
@testable import LFGKit

// MARK: - Fixture

/// Full fixture JSON covering both external_hosts (v3 SourceVolume) and drives (v3 VolumeBackend).
private let fixtureJSON = """
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
    },
    {
      "name": "104APPLE",
      "mount": "/Volumes/104APPLE",
      "role": "external_host",
      "available_gb": 100
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

private let malformedJSON = Data("not valid json {{{".utf8)

// MARK: - Tests

final class FleetRegistryV3Tests: XCTestCase {

    // MARK: allSourceVolumes

    func testAllSourceVolumesCountIsTwo() throws {
        let reg = try FleetRegistry(jsonData: fixtureJSON)
        XCTAssertEqual(reg.allSourceVolumes.count, 2)
    }

    func testSourceVolumeNamedYJMORE() throws {
        let reg = try FleetRegistry(jsonData: fixtureJSON)
        let vol = reg.sourceVolume(named: "YJ_MORE")
        XCTAssertNotNil(vol)
        XCTAssertEqual(vol?.name, "YJ_MORE")
        XCTAssertEqual(vol?.mount, "/Volumes/YJ_MORE")
        XCTAssertEqual(vol?.availableGB, 179)
        XCTAssertTrue(vol?.keepAwake ?? false, "YJ_MORE keepAwake must be true")
    }

    func testSourceVolumeNamed104APPLEHasKeepAwakeFalse() throws {
        let reg = try FleetRegistry(jsonData: fixtureJSON)
        let vol = reg.sourceVolume(named: "104APPLE")
        XCTAssertNotNil(vol)
        XCTAssertFalse(vol?.keepAwake ?? true, "104APPLE keepAwake must default to false")
    }

    func testSourceVolumeNamedNotFoundReturnsNil() throws {
        let reg = try FleetRegistry(jsonData: fixtureJSON)
        XCTAssertNil(reg.sourceVolume(named: "NOT_FOUND"))
    }

    // MARK: allVolumeBackends

    func testAllVolumeBackendsCountIsThree() throws {
        let reg = try FleetRegistry(jsonData: fixtureJSON)
        XCTAssertEqual(reg.allVolumeBackends.count, 3)
    }

    // MARK: volumeBackends(forHost:)

    func testVolumeBackendsForYJMORE() throws {
        let reg = try FleetRegistry(jsonData: fixtureJSON)
        let backends = reg.volumeBackends(forHost: "YJ_MORE")
        XCTAssertEqual(backends.count, 2)
        let ids = Set(backends.map(\.id))
        XCTAssertTrue(ids.contains("900HOOKS"))
        XCTAssertTrue(ids.contains("901DEVLIB"))
    }

    func testVolumeBackendsForInternalReturnsOneEntry() throws {
        let reg = try FleetRegistry(jsonData: fixtureJSON)
        let backends = reg.volumeBackends(forHost: "internal")
        XCTAssertEqual(backends.count, 1)
        XCTAssertEqual(backends.first?.id, "902APMDR")
    }

    func testVolumeBackendsForUnknownHostReturnsEmpty() throws {
        let reg = try FleetRegistry(jsonData: fixtureJSON)
        XCTAssertTrue(reg.volumeBackends(forHost: "NOT_FOUND").isEmpty)
    }

    // MARK: autoBackends(forHost:)

    func testAutoBackendsForYJMORE() throws {
        let reg = try FleetRegistry(jsonData: fixtureJSON)
        let auto = reg.autoBackends(forHost: "YJ_MORE")
        XCTAssertEqual(auto.count, 2, "Both 900HOOKS and 901DEVLIB have reconnect_policy auto")
    }

    func testAutoBackendsForInternalReturnsZero() throws {
        let reg = try FleetRegistry(jsonData: fixtureJSON)
        let auto = reg.autoBackends(forHost: "internal")
        XCTAssertEqual(auto.count, 0, "902APMDR has reconnect_policy manual")
    }

    // MARK: offloadRules per backend

    func test901DEVLIBOffloadRulesCount() throws {
        let reg = try FleetRegistry(jsonData: fixtureJSON)
        let backend = reg.allVolumeBackends.first(where: { $0.id == "901DEVLIB" })
        XCTAssertNotNil(backend)
        XCTAssertEqual(backend?.offloadRules.count, 2)
    }

    func test900HOOKSOffloadRulesCountIsZero() throws {
        let reg = try FleetRegistry(jsonData: fixtureJSON)
        let backend = reg.allVolumeBackends.first(where: { $0.id == "900HOOKS" })
        XCTAssertNotNil(backend)
        XCTAssertEqual(backend?.offloadRules.count, 0)
    }

    // MARK: Concurrency — consistent results across multiple inits

    func testConcurrentInitProducesConsistentResults() async throws {
        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let reg = try FleetRegistry(jsonData: fixtureJSON)
                    return reg.allVolumeBackends.count
                }
            }
            var counts: [Int] = []
            for try await count in group {
                counts.append(count)
            }
            return counts
        }
        XCTAssertTrue(results.allSatisfy { $0 == 3 }, "All concurrent inits must produce count of 3")
    }

    // MARK: Malformed JSON

    func testMalformedJSONThrowsOnInit() {
        XCTAssertThrowsError(try FleetRegistry(jsonData: malformedJSON))
    }
}

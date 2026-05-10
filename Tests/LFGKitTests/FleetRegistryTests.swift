import XCTest
@testable import LFGKit

// MARK: - Fixtures

private let minimalFleetJSON = """
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
    },
    {
      "id": "902APMDR",
      "image": "~/DevDrive/902APMDR.dmg.sparseimage",
      "mount": "/Volumes/DDRV902",
      "host": "internal",
      "reconnect_policy": "auto"
    },
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

private let emptyDrivesJSON = """
{ "version": "2.0", "drives": [] }
""".data(using: .utf8)!

private let malformedJSON = Data("not json".utf8)

// MARK: - Tests

final class FleetRegistryTests: XCTestCase {

    // MARK: Parsing

    func testParsesAllDrives() throws {
        let reg = try FleetRegistry(jsonData: minimalFleetJSON)
        XCTAssertEqual(reg.allDrives.count, 4)
    }

    func testEmptyDrivesArray() throws {
        let reg = try FleetRegistry(jsonData: emptyDrivesJSON)
        XCTAssertTrue(reg.allDrives.isEmpty)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try FleetRegistry(jsonData: malformedJSON))
    }

    // MARK: Host matching

    func testDrivesForKnownHost() throws {
        let reg = try FleetRegistry(jsonData: minimalFleetJSON)
        let drives = reg.drives(forHost: "YJ_MORE")
        XCTAssertEqual(drives.count, 3)  // 901, 904, manual-vol
    }

    func testDrivesForUnknownHostIsEmpty() throws {
        let reg = try FleetRegistry(jsonData: minimalFleetJSON)
        XCTAssertTrue(reg.drives(forHost: "NONEXISTENT").isEmpty)
    }

    // MARK: Auto reconnect filter

    func testAutoDrivesExcludesManualPolicy() throws {
        let reg = try FleetRegistry(jsonData: minimalFleetJSON)
        let auto = reg.autoDrives(forHost: "YJ_MORE")
        XCTAssertEqual(auto.count, 2)  // 901 + 904 only
        XCTAssertFalse(auto.contains(where: { $0.id == "manual-vol" }))
    }

    func testAutoDrivesForInternalHost() throws {
        let reg = try FleetRegistry(jsonData: minimalFleetJSON)
        let auto = reg.autoDrives(forHost: "internal")
        XCTAssertEqual(auto.count, 1)
        XCTAssertEqual(auto.first?.id, "902APMDR")
    }

    // MARK: Lookup by id

    func testDriveById() throws {
        let reg = try FleetRegistry(jsonData: minimalFleetJSON)
        let d = reg.drive(id: "901DEVLIB")
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.mount, "/Volumes/DDRV-901-DEVLIB")
    }

    func testDriveByIdMissing() throws {
        let reg = try FleetRegistry(jsonData: minimalFleetJSON)
        XCTAssertNil(reg.drive(id: "PHANTOM"))
    }

    // MARK: isKnownHost

    func testIsKnownHostTrue() throws {
        let reg = try FleetRegistry(jsonData: minimalFleetJSON)
        XCTAssertTrue(reg.isKnownHost("YJ_MORE"))
        XCTAssertTrue(reg.isKnownHost("internal"))
    }

    func testIsKnownHostFalse() throws {
        let reg = try FleetRegistry(jsonData: minimalFleetJSON)
        XCTAssertFalse(reg.isKnownHost("104APPLE"))
    }

    // MARK: Path expansion

    func testTildeExpansionInImagePath() throws {
        let reg = try FleetRegistry(jsonData: minimalFleetJSON)
        let drive = reg.drive(id: "902APMDR")!
        let resolved = drive.resolvedImagePath
        XCTAssertFalse(resolved.hasPrefix("~"), "Tilde should be expanded")
        XCTAssertTrue(resolved.hasPrefix("/"), "Resolved path should be absolute")
        XCTAssertTrue(resolved.hasSuffix("902APMDR.dmg.sparseimage"))
    }

    func testAbsolutePathUnchanged() throws {
        let reg = try FleetRegistry(jsonData: minimalFleetJSON)
        let drive = reg.drive(id: "901DEVLIB")!
        XCTAssertEqual(drive.resolvedImagePath, drive.image)
    }

    // MARK: allHosts

    func testAllHosts() throws {
        let reg = try FleetRegistry(jsonData: minimalFleetJSON)
        XCTAssertEqual(reg.allHosts, ["YJ_MORE", "internal"])
    }
}

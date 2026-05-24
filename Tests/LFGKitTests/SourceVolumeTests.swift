import XCTest
@testable import LFGKit

// MARK: - Fixtures

private let fullEntryJSON = """
{
  "name": "YJ_MORE",
  "mount": "/Volumes/YJ_MORE",
  "role": "external_host",
  "available_gb": 179,
  "status": "active",
  "keep_awake": true
}
""".data(using: .utf8)!

private let minimalEntryJSON = """
{
  "name": "104APPLE",
  "mount": "/Volumes/104APPLE",
  "role": "external_host"
}
""".data(using: .utf8)!

// MARK: - Tests

final class SourceVolumeTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: Codable round-trip

    func testCodableRoundTrip() throws {
        let original = try decoder.decode(SourceVolume.self, from: fullEntryJSON)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try decoder.decode(SourceVolume.self, from: encoded)

        XCTAssertEqual(decoded.name, "YJ_MORE")
        XCTAssertEqual(decoded.mount, "/Volumes/YJ_MORE")
        XCTAssertEqual(decoded.role, "external_host")
        XCTAssertEqual(decoded.availableGB, 179)
        XCTAssertEqual(decoded.status, "active")
        XCTAssertEqual(decoded.keepAwake, true)
    }

    // MARK: Optional defaults

    func testKeepAwakeDefaultsFalseWhenAbsent() throws {
        let volume = try decoder.decode(SourceVolume.self, from: minimalEntryJSON)
        XCTAssertFalse(volume.keepAwake, "keepAwake must default to false when key is absent")
    }

    func testAvailableGBIsNilWhenAbsent() throws {
        let volume = try decoder.decode(SourceVolume.self, from: minimalEntryJSON)
        XCTAssertNil(volume.availableGB)
    }

    func testStatusIsNilWhenAbsent() throws {
        let volume = try decoder.decode(SourceVolume.self, from: minimalEntryJSON)
        XCTAssertNil(volume.status)
    }

    // MARK: isMounted

    func testIsMountedReturnsFalseForNonExistentPath() throws {
        let json = """
        {
          "name": "FAKE",
          "mount": "/Volumes/NON_EXISTENT_XYZ_ABC",
          "role": "external_host"
        }
        """.data(using: .utf8)!
        let volume = try decoder.decode(SourceVolume.self, from: json)
        XCTAssertFalse(volume.isMounted, "isMounted should be false for a path that does not exist")
    }

    func testIsMountedReturnsTrueForExistingPath() throws {
        let json = """
        {
          "name": "TMP",
          "mount": "/tmp",
          "role": "external_host"
        }
        """.data(using: .utf8)!
        let volume = try decoder.decode(SourceVolume.self, from: json)
        XCTAssertTrue(volume.isMounted, "isMounted should be true for /tmp which always exists")
    }

    // MARK: Equatable

    func testEqualityForIdenticalDecodedValues() throws {
        let a = try decoder.decode(SourceVolume.self, from: fullEntryJSON)
        let b = try decoder.decode(SourceVolume.self, from: fullEntryJSON)
        XCTAssertEqual(a, b)
    }

    func testInequalityWhenNameDiffers() throws {
        let a = try decoder.decode(SourceVolume.self, from: fullEntryJSON)
        let json = """
        {
          "name": "OTHER",
          "mount": "/Volumes/YJ_MORE",
          "role": "external_host",
          "available_gb": 179,
          "status": "active",
          "keep_awake": true
        }
        """.data(using: .utf8)!
        let b = try decoder.decode(SourceVolume.self, from: json)
        XCTAssertNotEqual(a, b)
    }
}

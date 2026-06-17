import XCTest
@testable import LFGKit

// MARK: - Fixtures

private let devlibJSON = """
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
}
""".data(using: .utf8)!

private let minimalJSON = """
{
  "id": "902APMDR",
  "image": "/Internal/DDRV-902-APMDR.sparseimage",
  "mount": "/Volumes/DDRV-902-APMDR",
  "host": "internal",
  "reconnect_policy": "manual"
}
""".data(using: .utf8)!

private let dollarHomeJSON = """
{
  "id": "TEST_DOLLAR",
  "image": "$HOME/DevDrive/test.sparseimage",
  "mount": "/Volumes/TEST",
  "host": "internal"
}
""".data(using: .utf8)!

private let malformedSymlinkJSON = """
{
  "id": "BADLINKS",
  "image": "/Volumes/YJ_MORE/test.sparseimage",
  "mount": "/Volumes/BADLINKS",
  "host": "YJ_MORE",
  "reconnect_policy": "auto",
  "symlinks": [
    "valid source \u{2192} /Volumes/target",
    "no-arrow-here",
    "\u{2192} /Volumes/empty-source",
    "~/.tool \u{2192} "
  ]
}
""".data(using: .utf8)!

// MARK: - Tests

final class VolumeBackendTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: Codable round-trip

    func testCodableRoundTripPreservesAllFields() throws {
        let original = try decoder.decode(VolumeBackend.self, from: devlibJSON)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try decoder.decode(VolumeBackend.self, from: encoded)

        XCTAssertEqual(decoded.id, "901DEVLIB")
        XCTAssertEqual(decoded.image, "~/DevDrive/901DEVLIB.sparseimage")
        XCTAssertEqual(decoded.mount, "/Volumes/DDRV-901-DEVLIB")
        XCTAssertEqual(decoded.host, "YJ_MORE")
        XCTAssertEqual(decoded.tier, "cold")
        XCTAssertEqual(decoded.purpose, "Xcode DerivedData")
        XCTAssertEqual(decoded.reconnectPolicy, "auto")
        XCTAssertEqual(decoded.rawSymlinks.count, 2)
    }

    // MARK: offloadRules

    func testOffloadRulesEmptyWhenNoSymlinks() throws {
        let backend = try decoder.decode(VolumeBackend.self, from: minimalJSON)
        XCTAssertTrue(backend.rawSymlinks.isEmpty)
        XCTAssertTrue(backend.offloadRules.isEmpty)
    }

    func testOffloadRulesCountMatchesValidSymlinks() throws {
        let backend = try decoder.decode(VolumeBackend.self, from: devlibJSON)
        XCTAssertEqual(backend.offloadRules.count, 2)
    }

    func testOffloadRulesParseSourceAndTargetCorrectly() throws {
        let backend = try decoder.decode(VolumeBackend.self, from: devlibJSON)
        let rules = backend.offloadRules
        XCTAssertTrue(rules.contains(where: {
            $0.source == "~/.npm-cache" && $0.target == "/Volumes/DDRV-901-DEVLIB/npm-cache"
        }))
        XCTAssertTrue(rules.contains(where: {
            $0.source == "~/.asdf" && $0.target == "/Volumes/DDRV-901-DEVLIB/asdf"
        }))
    }

    func testMalformedSymlinkStringsAreSilentlyDropped() throws {
        let backend = try decoder.decode(VolumeBackend.self, from: malformedSymlinkJSON)
        // "no-arrow-here", "→ /Volumes/empty-source", "~/.tool → " are all malformed
        // Only "valid source → /Volumes/target" should survive
        XCTAssertEqual(backend.offloadRules.count, 1)
        XCTAssertEqual(backend.offloadRules.first?.source, "valid source")
        XCTAssertEqual(backend.offloadRules.first?.target, "/Volumes/target")
    }

    // MARK: isAutoReconnect

    func testIsAutoReconnectTrueForAutoPolicyString() throws {
        let backend = try decoder.decode(VolumeBackend.self, from: devlibJSON)
        XCTAssertTrue(backend.isAutoReconnect)
    }

    func testIsAutoReconnectFalseForManualPolicy() throws {
        let backend = try decoder.decode(VolumeBackend.self, from: minimalJSON)
        XCTAssertFalse(backend.isAutoReconnect)
    }

    func testIsAutoReconnectFalseWhenPolicyAbsent() throws {
        let backend = try decoder.decode(VolumeBackend.self, from: dollarHomeJSON)
        XCTAssertFalse(backend.isAutoReconnect)
    }

    // MARK: resolvedImagePath

    func testResolvedImagePathExpandsTildePrefix() throws {
        let backend = try decoder.decode(VolumeBackend.self, from: devlibJSON)
        let resolved = backend.resolvedImagePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(resolved.hasPrefix("~/"), "resolvedImagePath must not start with ~/")
        XCTAssertTrue(resolved.hasPrefix(home), "resolvedImagePath must start with home directory")
        XCTAssertTrue(resolved.hasSuffix("901DEVLIB.sparseimage"))
    }

    func testResolvedImagePathExpandsDollarHomePrefix() throws {
        let backend = try decoder.decode(VolumeBackend.self, from: dollarHomeJSON)
        let resolved = backend.resolvedImagePath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(resolved.hasPrefix("$HOME/"))
        XCTAssertTrue(resolved.hasPrefix(home))
        XCTAssertTrue(resolved.hasSuffix("test.sparseimage"))
    }

    func testResolvedImagePathReturnsAbsolutePathUnchanged() throws {
        let backend = try decoder.decode(VolumeBackend.self, from: minimalJSON)
        XCTAssertEqual(backend.resolvedImagePath, "/Internal/DDRV-902-APMDR.sparseimage")
    }

    // MARK: rawSymlinks default

    func testRawSymlinksDefaultsToEmptyArrayWhenKeyAbsent() throws {
        let backend = try decoder.decode(VolumeBackend.self, from: minimalJSON)
        XCTAssertEqual(backend.rawSymlinks, [])
    }
}

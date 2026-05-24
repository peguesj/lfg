import XCTest
@testable import LFGKit

// MARK: - Tests

final class OffloadRuleTests: XCTestCase {

    // MARK: init(raw:) — valid input

    func testInitParsesValidArrowString() {
        let rule = OffloadRule(raw: "~/.npm-cache \u{2192} /Volumes/DDRV-901-DEVLIB/npm-cache")
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.source, "~/.npm-cache")
        XCTAssertEqual(rule?.target, "/Volumes/DDRV-901-DEVLIB/npm-cache")
    }

    func testInitParsesAbsoluteSourcePath() {
        let rule = OffloadRule(raw: "/Users/jeremiah/.asdf \u{2192} /Volumes/DDRV-901-DEVLIB/asdf")
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.source, "/Users/jeremiah/.asdf")
        XCTAssertEqual(rule?.target, "/Volumes/DDRV-901-DEVLIB/asdf")
    }

    // MARK: init(raw:) — invalid input

    func testInitReturnsNilWhenNoArrowSeparator() {
        let rule = OffloadRule(raw: "~/.npm-cache /Volumes/DDRV-901-DEVLIB/npm-cache")
        XCTAssertNil(rule, "Should return nil when no arrow separator is present")
    }

    func testInitReturnsNilWhenSourceSideIsEmpty() {
        let rule = OffloadRule(raw: " \u{2192} /Volumes/DDRV-901-DEVLIB/npm-cache")
        XCTAssertNil(rule, "Should return nil when source side is empty")
    }

    func testInitReturnsNilWhenTargetSideIsEmpty() {
        let rule = OffloadRule(raw: "~/.npm-cache \u{2192} ")
        XCTAssertNil(rule, "Should return nil when target side is empty")
    }

    func testInitReturnsNilForEmptyString() {
        let rule = OffloadRule(raw: "")
        XCTAssertNil(rule, "Should return nil for an empty string")
    }

    func testInitReturnsNilForArrowOnly() {
        let rule = OffloadRule(raw: " \u{2192} ")
        XCTAssertNil(rule, "Should return nil when both sides are empty whitespace")
    }

    // MARK: resolvedSource

    func testResolvedSourceExpandsTilde() {
        let rule = OffloadRule(raw: "~/.npm-cache \u{2192} /Volumes/DDRV-901-DEVLIB/npm-cache")!
        let resolved = rule.resolvedSource
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(resolved.hasPrefix("~/"), "resolvedSource must not start with ~/")
        XCTAssertTrue(resolved.hasPrefix(home), "resolvedSource must start with the home directory path")
        XCTAssertTrue(resolved.hasSuffix(".npm-cache"))
    }

    func testResolvedSourceLeavesAbsolutePathUnchanged() {
        let absolutePath = "/Users/jeremiah/.asdf"
        let rule = OffloadRule(raw: "\(absolutePath) \u{2192} /Volumes/DDRV-901-DEVLIB/asdf")!
        XCTAssertEqual(rule.resolvedSource, absolutePath)
    }

    func testResolvedSourceWithNoTildeReturnsSourceUnchanged() {
        let source = "/opt/local/share/some-tool"
        let rule = OffloadRule(raw: "\(source) \u{2192} /Volumes/target")!
        XCTAssertEqual(rule.resolvedSource, source)
    }

    // MARK: isHealthy

    func testIsHealthyReturnsFalseForNonExistentPath() {
        // A path that definitely does not exist as a symlink.
        let rule = OffloadRule(raw: "/tmp/lfg_test_nonexistent_symlink_xyz \u{2192} /Volumes/SomeTarget")!
        XCTAssertFalse(rule.isHealthy, "isHealthy must be false when the source path does not exist")
    }

    // MARK: Equatable

    func testEqualityForSameSourceAndTarget() {
        let raw = "~/.npm-cache \u{2192} /Volumes/DDRV-901-DEVLIB/npm-cache"
        let a = OffloadRule(raw: raw)!
        let b = OffloadRule(raw: raw)!
        XCTAssertEqual(a, b)
    }

    func testInequalityWhenTargetDiffers() {
        let a = OffloadRule(raw: "~/.npm-cache \u{2192} /Volumes/DDRV-901-DEVLIB/npm-cache")!
        let b = OffloadRule(raw: "~/.npm-cache \u{2192} /Volumes/DDRV-901-DEVLIB/npm-cache-v2")!
        XCTAssertNotEqual(a, b)
    }
}

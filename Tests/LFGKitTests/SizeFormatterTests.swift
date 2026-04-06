import XCTest
@testable import LFGKit

final class SizeFormatterTests: XCTestCase {
    func testFormatZero() {
        XCTAssertEqual(SizeFormatter.format(0), "0 B")
    }

    func testFormatBytes() {
        XCTAssertEqual(SizeFormatter.format(512), "512 B")
    }

    func testFormatKB() {
        XCTAssertEqual(SizeFormatter.format(1_536), "1.5 KB")
    }

    func testFormatMB() {
        XCTAssertEqual(SizeFormatter.format(104_857_600), "100.0 MB")
    }

    func testFormatGB() {
        XCTAssertEqual(SizeFormatter.format(5_368_709_120), "5.0 GB")
    }

    func testFormatTB() {
        XCTAssertEqual(SizeFormatter.format(1_099_511_627_776), "1.0 TB")
    }

    func testParseGB() {
        // 42.3 * 1_073_741_824 = 45_419_279_155 (UInt64 truncation of floating point)
        XCTAssertEqual(SizeFormatter.parse("42.3 GB"), 45_419_279_155)
    }

    func testParseMB() {
        XCTAssertEqual(SizeFormatter.parse("100MB"), 104_857_600)
    }

    func testParseInvalid() {
        XCTAssertNil(SizeFormatter.parse("not a size"))
    }
}

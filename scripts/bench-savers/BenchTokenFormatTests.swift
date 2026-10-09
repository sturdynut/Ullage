import XCTest
@testable import UllageCore

final class BenchTokenFormatTests: XCTestCase {
    func testBillions() {
        XCTAssertEqual(TokenFormat.compact(1_500_000_000), "1.5B")
        XCTAssertEqual(TokenFormat.compact(12_000_000_000), "12.0B")
    }
    func testNegative() {
        XCTAssertEqual(TokenFormat.compact(-845), "-845")
        XCTAssertEqual(TokenFormat.compact(-8_400), "-8.4k")
        XCTAssertEqual(TokenFormat.compact(-1_200_000), "-1.2M")
    }
    func testUnchanged() {
        XCTAssertEqual(TokenFormat.compact(845), "845")
        XCTAssertEqual(TokenFormat.compact(84_000), "84k")
        XCTAssertEqual(TokenFormat.compact(999_999_999), "1000.0M")
    }
}

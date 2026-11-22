import XCTest
@testable import Comics

final class WindowFormTests: XCTestCase {
    func testNarrowPhoneCover() {
        XCTAssertEqual(WindowForm(size: .init(width: 466, height: 678)), .narrow)
    }

    func testWideOpenDuo() {
        XCTAssertEqual(WindowForm(size: .init(width: 951, height: 669)), .wide)
    }

    func testWidthBoundaryIsInclusive() {
        XCTAssertEqual(WindowForm(size: .init(width: 700, height: 699)), .wide)
    }

    func testBelowWidthThresholdIsNarrow() {
        XCTAssertEqual(WindowForm(size: .init(width: 699, height: 400)), .narrow)
    }

    func testPortraitTabletIsNarrow() {
        XCTAssertEqual(WindowForm(size: .init(width: 800, height: 900)), .narrow)
    }
}

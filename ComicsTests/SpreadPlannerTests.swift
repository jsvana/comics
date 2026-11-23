import XCTest
@testable import Comics

final class SpreadPlannerTests: XCTestCase {
    private let wideCanvas = CGSize(width: 951, height: 669)
    private let narrowCanvas = CGSize(width: 466, height: 678)
    private let portrait = CGSize(width: 800, height: 1135)   // QC-like
    private let strip = CGSize(width: 1000, height: 322)      // DoA-like

    private func plan(_ c: CGSize?, _ n: CGSize?, canvas: CGSize? = nil, form: WindowForm = .wide) -> SpreadLayout {
        let canvas = canvas ?? wideCanvas
        return SpreadPlanner.layout(current: c, next: n, canvas: canvas, form: form)
    }

    func testTwoPortraitPagesGoSideBySide() {
        XCTAssertEqual(plan(portrait, portrait), .sideBySide)
    }

    func testTwoSquareStripsGoSideBySide() {
        let square = CGSize(width: 800, height: 800)
        XCTAssertEqual(plan(square, square), .sideBySide)
    }

    func testWideStripThenTallInfographicIsSingle() {
        XCTAssertEqual(plan(strip, CGSize(width: 740, height: 2000)), .single)
    }

    func testTwoWideStripsStack() {
        XCTAssertEqual(plan(strip, strip), .stacked)
    }

    func testMixedShapesGoSingle() {
        XCTAssertEqual(plan(portrait, strip), .single)
    }

    func testRatio247StripsStack() {
        let s = CGSize(width: 740, height: 300)
        XCTAssertEqual(plan(s, s), .stacked)
    }

    func testVeryTallPagesGoSingle() {
        let t = CGSize(width: 600, height: 2400)
        XCTAssertEqual(plan(t, t), .single)
    }

    func testNoNextIsSingle() {
        XCTAssertEqual(plan(portrait, nil), .single)
    }

    func testUnknownCurrentIsSingle() {
        XCTAssertEqual(plan(nil, portrait), .single)
    }

    func testNarrowFormIsSingle() {
        XCTAssertEqual(plan(portrait, portrait, canvas: narrowCanvas, form: .narrow), .single)
    }

    func testCounts() {
        XCTAssertEqual(SpreadPlanner.count(.single), 1)
        XCTAssertEqual(SpreadPlanner.count(.sideBySide), 2)
        XCTAssertEqual(SpreadPlanner.count(.stacked), 2)
    }
}

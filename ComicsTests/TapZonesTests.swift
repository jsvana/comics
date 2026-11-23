import SwiftUI
import XCTest
@testable import Comics

final class TapZonesTests: XCTestCase {
    private let closed = CGSize(width: 466, height: 678)
    private let open = CGSize(width: 951, height: 669)
    private let none = EdgeInsets()
    private let camera = EdgeInsets(top: 40, leading: 0, bottom: 20, trailing: 0)

    func testNarrowColumnIsTheRight96PointsSplitAThirdPreviousTwoThirdsNext() {
        let f = TapZones.frames(for: .narrow, canvas: closed, safeArea: none)
        XCTAssertEqual(f.previous, CGRect(x: 370, y: 0, width: 96, height: 226))
        XCTAssertEqual(f.next, CGRect(x: 370, y: 226, width: 96, height: 452))
        XCTAssertEqual(f.toggleChrome, CGRect(x: 0, y: 0, width: 370, height: 678))
    }

    func testNarrowColumnStaysBetweenTheSafeAreaInsets() {
        let f = TapZones.frames(for: .narrow, canvas: closed, safeArea: camera)
        XCTAssertEqual(f.previous.minY, 40, "never under the camera")
        XCTAssertEqual(f.next.maxY, 658)
        XCTAssertEqual(f.previous.height, (658 - 40) / 3, accuracy: 0.001)
        XCTAssertEqual(f.previous.maxY, f.next.minY, accuracy: 0.001)
        XCTAssertEqual(f.next.minX, 370)
        XCTAssertEqual(f.next.maxX, 466)
    }

    func testNarrowTapsMapToZones() {
        func zone(_ x: CGFloat, _ y: CGFloat) -> TapZones.Zone {
            TapZones.zone(at: CGPoint(x: x, y: y), form: .narrow, canvas: closed, safeArea: camera)
        }
        XCTAssertEqual(zone(440, 100), .previous)
        XCTAssertEqual(zone(440, 500), .next)
        XCTAssertEqual(zone(440, 20), .toggleChrome, "the camera area turns no page")
        XCTAssertEqual(zone(440, 670), .toggleChrome, "below the bottom inset")
        XCTAssertEqual(zone(50, 339), .toggleChrome, "the left third no longer goes back")
        XCTAssertEqual(zone(233, 339), .toggleChrome)
        XCTAssertEqual(zone(360, 500), .toggleChrome, "just left of the column")
    }

    func testWideKeepsTheOuterThirds() {
        let f = TapZones.frames(for: .wide, canvas: open, safeArea: camera)
        XCTAssertEqual(f.previous, CGRect(x: 0, y: 0, width: 317, height: 669))
        XCTAssertEqual(f.toggleChrome, CGRect(x: 317, y: 0, width: 317, height: 669))
        XCTAssertEqual(f.next, CGRect(x: 634, y: 0, width: 317, height: 669))
        XCTAssertEqual(TapZones.zone(at: CGPoint(x: 100, y: 10), form: .wide, canvas: open, safeArea: camera), .previous)
        XCTAssertEqual(TapZones.zone(at: CGPoint(x: 475, y: 300), form: .wide, canvas: open, safeArea: camera), .toggleChrome)
        XCTAssertEqual(TapZones.zone(at: CGPoint(x: 900, y: 660), form: .wide, canvas: open, safeArea: camera), .next)
    }

    func testNarrowColumnNeverWiderThanTheWindow() {
        let f = TapZones.frames(for: .narrow, canvas: CGSize(width: 60, height: 300), safeArea: none)
        XCTAssertEqual(f.next.minX, 0)
        XCTAssertEqual(f.next.width, 60)
        XCTAssertEqual(f.toggleChrome.width, 0)
    }
}

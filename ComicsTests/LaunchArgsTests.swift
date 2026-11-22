import XCTest
@testable import Comics

final class LaunchArgsTests: XCTestCase {
    func testParsesAllArguments() {
        let args = LaunchArgs(["app", "-canvas", "951x669", "-openComic", "qc", "-goto", "2140",
                               "-fixtureCatalog", "YES", "-icloud", "NO"])
        XCTAssertEqual(args.canvas, CGSize(width: 951, height: 669))
        XCTAssertEqual(args.openComic, "qc")
        XCTAssertEqual(args.goto, 2140)
        XCTAssertTrue(args.fixtureCatalog)
        XCTAssertFalse(args.resetFixture)
        XCTAssertFalse(args.icloud)
    }

    func testDefaults() {
        let args = LaunchArgs(["app"])
        XCTAssertNil(args.canvas)
        XCTAssertNil(args.openComic)
        XCTAssertNil(args.goto)
        XCTAssertFalse(args.fixtureCatalog)
        XCTAssertFalse(args.resetFixture)
        XCTAssertTrue(args.icloud)
    }

    func testJunkCanvasIsNil() {
        XCTAssertNil(LaunchArgs(["app", "-canvas", "junk"]).canvas)
    }

    func testResetFixture() {
        XCTAssertTrue(LaunchArgs(["app", "-resetFixture", "YES"]).resetFixture)
    }
}

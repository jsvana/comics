import XCTest

/// The reader against the bundled fixture comic (no network), at the closed and open Duo sizes.
/// Run with `TEST_RUNNER_COMICS_SHOTS=1` to save screenshots to /tmp/comics-shots/.
final class ReaderUITests: XCTestCase {
    private static let narrow = "466x678"
    private static let wide = "951x669"
    private static let timeout: TimeInterval = 10

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(canvas: String, reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-fixtureCatalog", "YES", "-icloud", "NO", "-openComic", "fixture", "-canvas", canvas]
            + (reset ? ["-resetFixture", "YES"] : []) + extra
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func assertShows(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(app, id).waitForExistence(timeout: Self.timeout), "\(id) never appeared", file: file, line: line)
    }

    /// The tap areas do not take touches themselves (the scroll view under them does), so tap
    /// their centre by coordinate rather than through hit-testing.
    private func tapZone(_ app: XCUIApplication, _ id: String) {
        let zone = element(app, id)
        XCTAssertTrue(zone.waitForExistence(timeout: Self.timeout), "\(id) missing")
        zone.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func shot(_ name: String) {
        guard ProcessInfo.processInfo.environment["COMICS_SHOTS"] != nil else { return }
        let dir = URL(fileURLWithPath: "/tmp/comics-shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    func testNarrowTapThrough() {
        let app = launch(canvas: Self.narrow)
        assertShows(app, "strip-1")
        shot("narrow-strip-1")
        tapZone(app, "reader-next")
        assertShows(app, "strip-2")
        shot("narrow-strip-2")
        app.terminate()

        let again = launch(canvas: Self.narrow, reset: false)
        assertShows(again, "strip-2")
    }

    func testWideShowsTwo() {
        let app = launch(canvas: Self.wide)
        assertShows(app, "strip-1")
        assertShows(app, "strip-2")
        shot("wide-strips-1-2")
        tapZone(app, "reader-next")
        assertShows(app, "strip-3")
        assertShows(app, "strip-4")
        shot("wide-strips-3-4")
    }

    func testNarrowTapZonesSitInTheRightEdgeColumn() {
        let app = launch(canvas: Self.narrow, extra: ["-goto", "2"])
        assertShows(app, "strip-2")
        shot("narrow-hints")  // within the hints' two seconds
        let canvas = element(app, "windowForm-narrow").frame
        XCTAssertEqual(canvas.width, 466, accuracy: 1)
        let prev = element(app, "reader-prev").frame
        let next = element(app, "reader-next").frame
        for (name, zone) in [("reader-prev", prev), ("reader-next", next)] {
            XCTAssertGreaterThanOrEqual(zone.minX, canvas.maxX - 96 - 0.5, "\(name) is in the right 96 pt")
            XCTAssertLessThanOrEqual(zone.maxX, canvas.maxX + 0.5, "\(name) is in the right 96 pt")
            XCTAssertGreaterThan(zone.height, 100)
        }
        XCTAssertLessThanOrEqual(prev.maxY, next.minY + 0.5, "Previous is above Next")
        XCTAssertGreaterThan(next.height, prev.height, "Next is the larger, lower part")

        // The left third now toggles the chrome rather than going back.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: canvas.minX + canvas.width / 6, dy: canvas.midY)).tap()
        XCTAssertTrue(app.buttons["reader-menu"].waitForExistence(timeout: Self.timeout), "chrome did not show")
        XCTAssertTrue(element(app, "strip-2").exists)
        XCTAssertFalse(element(app, "strip-1").exists, "the left third did not go back")
        shot("narrow-chrome-hints")
    }

    func testWideFinishingOnAPairMovesTheBookmarkToTheLastStrip() {
        let app = launch(canvas: Self.wide, extra: ["-goto", "11"])
        assertShows(app, "strip-11")
        assertShows(app, "strip-12")
        // The "Caught up" card below the pair can make the spread taller than the screen, in
        // which case the first tap scrolls to it and the next one turns the page.
        for _ in 0..<3 where element(app, "strip-11").exists {
            tapZone(app, "reader-next")
            _ = element(app, "strip-11").waitForNonExistence(timeout: 2)
        }
        XCTAssertFalse(element(app, "strip-11").exists, "the last strip is shown alone")
        assertShows(app, "strip-12")
        assertShows(app, "caught-up")
        shot("wide-finished-12")
        app.terminate()

        let again = launch(canvas: Self.wide, reset: false)
        assertShows(again, "strip-12")
        XCTAssertFalse(element(again, "strip-11").exists, "the saved place is the last strip")
    }

    func testTallStripScrollsBeforeAdvancing() {
        let app = launch(canvas: Self.narrow, extra: ["-goto", "5"])
        assertShows(app, "strip-5")
        shot("narrow-tall-5-top")
        tapZone(app, "reader-next")
        XCTAssertTrue(element(app, "strip-5").exists, "the first tap should scroll, not advance")
        XCTAssertFalse(element(app, "strip-6").exists)
        shot("narrow-tall-5-scrolled")
        for _ in 0..<10 where !element(app, "strip-6").exists {
            tapZone(app, "reader-next")
        }
        assertShows(app, "strip-6")
    }

    func testTallStripInWide() {
        let app = launch(canvas: Self.wide, extra: ["-goto", "5"])
        assertShows(app, "strip-5")
        XCTAssertFalse(element(app, "strip-6").exists, "a tall strip gets the screen to itself")
        shot("wide-tall-5")
    }

    func testFailedStripIsPassable() {
        let app = launch(canvas: Self.narrow, extra: ["-goto", "7"])
        assertShows(app, "strip-failed-7")
        shot("narrow-failed-7")
        tapZone(app, "reader-next")
        assertShows(app, "strip-8")
    }

    func testBonusAndHoverText() {
        let app = launch(canvas: Self.narrow, extra: ["-goto", "3"])
        assertShows(app, "strip-3")
        assertShows(app, "strip-bonus")
        XCTAssertTrue(app.staticTexts["This one has a bonus panel below."].exists)
        XCTAssertTrue(app.staticTexts["Fixture 3 · #3"].exists)
        shot("narrow-bonus-3")
    }

    func testJumpAndBack() {
        let app = launch(canvas: Self.narrow)
        assertShows(app, "strip-1")
        tapZone(app, "reader-middle")
        let menu = app.buttons["reader-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: Self.timeout), "chrome did not show")
        shot("narrow-chrome")
        menu.tap()
        let latest = app.buttons["Latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: Self.timeout))
        latest.tap()
        assertShows(app, "strip-12")
        assertShows(app, "caught-up")
        assertShows(app, "back-chip")
        shot("narrow-latest-with-chip")
        element(app, "back-chip").tap()
        assertShows(app, "strip-1")
        XCTAssertFalse(element(app, "back-chip").exists)
    }

    func testWideChromeAndLatest() {
        let app = launch(canvas: Self.wide)
        assertShows(app, "strip-2")
        tapZone(app, "reader-middle")
        XCTAssertTrue(app.buttons["reader-menu"].waitForExistence(timeout: Self.timeout))
        shot("wide-chrome")
        app.buttons["reader-menu"].tap()
        app.buttons["Latest"].tap()
        assertShows(app, "strip-12")
        assertShows(app, "back-chip")
        shot("wide-latest-with-chip")
    }

    func testWideMenuOffersOriginalForBothStrips() {
        let app = launch(canvas: Self.wide)
        assertShows(app, "strip-1")
        assertShows(app, "strip-2")
        tapZone(app, "reader-middle")
        let menu = app.buttons["reader-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: Self.timeout), "chrome did not show")
        menu.tap()
        XCTAssertTrue(app.buttons["Open original page #1"].waitForExistence(timeout: Self.timeout))
        XCTAssertTrue(app.buttons["Open original page #2"].exists)
        XCTAssertTrue(app.buttons["Reload strip #1"].exists)
        XCTAssertTrue(app.buttons["Reload strip #2"].exists)
        shot("wide-menu")
    }
}

import XCTest

/// Launch → library → add a comic → read to the end → back → the card says so, and still does
/// after a relaunch. Against the bundled fixture comic (no network), at both Duo sizes.
/// Run with `TEST_RUNNER_COMICS_SHOTS=1` to save screenshots to /tmp/comics-shots/.
final class LibraryUITests: XCTestCase {
    private static let timeout: TimeInterval = 10

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(canvas: String, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-fixtureCatalog", "YES", "-icloud", "NO", "-canvas", canvas]
            + (reset ? ["-resetFixture", "YES"] : [])
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func assertShows(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(app, id).waitForExistence(timeout: Self.timeout), "\(id) never appeared", file: file, line: line)
    }

    /// Waits until the card's accessibility value (its status line) reads `status`.
    private func assertCard(_ app: XCUIApplication, says status: String, file: StaticString = #filePath, line: UInt = #line) {
        let card = element(app, "card-fixture")
        XCTAssertTrue(card.waitForExistence(timeout: Self.timeout), "no card", file: file, line: line)
        let match = expectation(for: NSPredicate(format: "value == %@", status), evaluatedWith: card)
        let result = XCTWaiter().wait(for: [match], timeout: Self.timeout)
        XCTAssertEqual(result, .completed, "card says \(String(describing: card.value)), not \(status)", file: file, line: line)
    }

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

    private func addReadAndReturn(canvas: String, prefix: String) {
        let app = launch(canvas: canvas, reset: true)
        assertShows(app, "library-empty")
        shot("\(prefix)-library-empty")

        app.buttons["library-empty-add"].tap()
        assertShows(app, "add-fixture")
        shot("\(prefix)-add-sheet")
        app.buttons["add-fixture"].tap()
        let first = app.buttons["Start from the first strip"]
        XCTAssertTrue(first.waitForExistence(timeout: Self.timeout), "no start choice")
        first.tap()
        assertShows(app, "added-fixture")
        shot("\(prefix)-add-sheet-added")
        app.buttons["catalog-done"].tap()

        assertCard(app, says: "1 of 12")
        shot("\(prefix)-library-card")

        element(app, "card-fixture").tap()
        assertShows(app, "strip-1")
        // Tap next until the last strip shows (the tall strip 5 takes a few taps to scroll through).
        for _ in 0..<40 where !element(app, "strip-12").exists {
            tapZone(app, "reader-next")
        }
        assertShows(app, "strip-12")
        tapZone(app, "reader-middle")
        let back = app.buttons["reader-library"]
        XCTAssertTrue(back.waitForExistence(timeout: Self.timeout), "chrome did not show")
        back.tap()

        assertCard(app, says: "Caught up")
        shot("\(prefix)-library-caught-up")

        app.buttons["library-settings"].tap()
        assertShows(app, "settings-hover")
        shot("\(prefix)-settings")
        app.buttons["settings-done"].tap()
        app.terminate()

        let again = launch(canvas: canvas, reset: false)
        assertCard(again, says: "Caught up")
    }

    func testNarrowAddReadAndReturn() {
        addReadAndReturn(canvas: "466x678", prefix: "narrow")
    }

    func testWideAddReadAndReturn() {
        addReadAndReturn(canvas: "951x669", prefix: "wide")
    }
}

import GRDB
import XCTest
@testable import Comics

/// The reader state machine against the bundled fixture comic (12 strips: 800x1135 portraits,
/// strip 5 is 600x3000, strip 7's page has no image), with an in-memory database.
@MainActor
final class ReaderModelTests: XCTestCase {
    private var dir: URL!
    private var db: Comics.Database!
    private var library: LibraryStore!
    private var places: PlaceKeeper!
    private var loader: StripLoader!
    private var def: ComicDef!
    private var http: ScriptedFixtureHTTP!

    private static let narrow = CGSize(width: 466, height: 678)
    private static let wide = CGSize(width: 951, height: 669)

    override func setUp() async throws {
        let fixture = try XCTUnwrap(FixtureHTTP.bundled(), "the app bundle has no Fixtures folder")
        http = ScriptedFixtureHTTP(fixture)
        let data = try Data(contentsOf: fixture.root.appendingPathComponent("fixture-catalog.json"))
        def = try XCTUnwrap(JSONDecoder().decode(Catalog.self, from: data).comics.first { $0.id == "fixture" })
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("readermodel-\(UUID().uuidString)")
        db = try Comics.Database(path: nil)
        library = LibraryStore(db: db, index: IndexFetcher(http: http))
        places = PlaceKeeper(db: db)
        loader = StripLoader(db: db, library: library, extractor: StripExtractor(http: http),
                             images: ImageCache(http: http, directory: dir), unmetered: { false })
        try await library.add(def, start: .first)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeModel(_ canvas: CGSize) throws -> ReaderModel {
        let model = try ReaderModel(def: def, library: library, places: places, loader: loader)
        model.canvas = canvas
        model.form = WindowForm(size: canvas)
        return model
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func settled(_ model: ReaderModel, _ ordinals: [Int]) -> Bool {
        ordinals.allSatisfy { n in
            switch model.strips[n] {
            case .ready, .failed: return true
            default: return false
            }
        }
    }

    func testFixtureComicHasTwelveStrips() throws {
        let model = try makeModel(Self.narrow)
        XCTAssertEqual(model.count, 12)
        XCTAssertEqual(model.first, 1)
    }

    func testNarrowNextMovesOneAndWritesBookmark() async throws {
        let model = try makeModel(Self.narrow)
        await waitUntil("strips 1 and 2") { settled(model, [1, 2]) }
        XCTAssertEqual(model.layout, .single)
        model.next()
        XCTAssertEqual(model.first, 2)
        XCTAssertEqual(places.bookmark(def.id), 2)
    }

    func testWideUsesSideBySideAndMovesByTwo() async throws {
        let model = try makeModel(Self.wide)
        await waitUntil("side by side") { model.layout == .sideBySide }
        model.next()
        XCTAssertEqual(model.first, 3)
        XCTAssertEqual(places.bookmark(def.id), 3)
    }

    func testWideNextThenPreviousReturnsToSameStrip() async throws {
        let model = try makeModel(Self.wide)
        await waitUntil("side by side") { model.layout == .sideBySide }
        model.next()
        await waitUntil("strips 3 and 4") { settled(model, [3, 4]) }
        model.previous()
        XCTAssertEqual(model.first, 1)
        XCTAssertEqual(places.bookmark(def.id), 1)
    }

    func testWidePreviousOverSingleTallStripStepsOne() async throws {
        let model = try makeModel(Self.wide)
        model.go(to: 6)
        await waitUntil("strips 4 to 6") { settled(model, [4, 5, 6]) }
        model.previous()
        XCTAssertEqual(model.first, 5, "4 and 5 do not pair (5 is too tall), so the previous spread is 5 alone")
    }

    func testGoToSetsBackTargetAndGoBackReturns() async throws {
        let model = try makeModel(Self.narrow)
        model.go(to: 9)
        XCTAssertEqual(model.first, 9)
        XCTAssertEqual(model.backTarget, 1)
        XCTAssertEqual(model.history.first?.ordinal, 1)
        model.goBack()
        XCTAssertEqual(model.first, 1)
        XCTAssertNil(model.backTarget)
        XCTAssertEqual(places.bookmark(def.id), 1)
    }

    func testNextClearsBackTarget() async throws {
        let model = try makeModel(Self.narrow)
        model.go(to: 9)
        await waitUntil("strip 9") { settled(model, [9]) }
        model.next()
        XCTAssertEqual(model.first, 10)
        XCTAssertNil(model.backTarget)
    }

    func testNextAtLastStripDoesNothing() async throws {
        let model = try makeModel(Self.narrow)
        model.go(to: 12)
        await waitUntil("strip 12") { settled(model, [12]) }
        XCTAssertTrue(model.atEnd)
        model.next()
        XCTAssertEqual(model.first, 12)
        XCTAssertEqual(places.bookmark(def.id), 12)
    }

    func testWideNextAtFinalPairStepsToLastStrip() async throws {
        let model = try makeModel(Self.wide)
        model.go(to: 11)
        await waitUntil("side by side 11-12") { model.layout == .sideBySide }
        XCTAssertTrue(model.atEnd)
        let history = places.history(def.id)
        model.next()
        XCTAssertEqual(model.first, 12, "the last strip was read, so the bookmark moves onto it")
        XCTAssertEqual(places.bookmark(def.id), 12)
        XCTAssertEqual(model.spread, [12])
        XCTAssertTrue(model.atEnd)
        XCTAssertNil(model.backTarget)
        XCTAssertEqual(places.history(def.id), history, "a plain step: no history entry")
        XCTAssertEqual(PlaceKeeper.status(bookmark: places.bookmark(def.id), count: model.count), .caughtUp)
        model.next()
        XCTAssertEqual(model.first, 12, "nothing further")
        model.previous()
        XCTAssertEqual(model.first, 11, "back to the final pair the reader came from")
        XCTAssertEqual(places.bookmark(def.id), 11)
        await waitUntil("side by side 11-12 again") { model.layout == .sideBySide }
        XCTAssertEqual(model.spread, [11, 12])
    }

    func testWideReadingThroughEndingOnAPairIsCaughtUp() async throws {
        let model = try makeModel(Self.wide)
        model.go(to: 9)
        await waitUntil("side by side 9-10") { model.layout == .sideBySide }
        model.next()
        XCTAssertEqual(model.first, 11)
        await waitUntil("side by side 11-12") { model.layout == .sideBySide }
        model.next()
        XCTAssertEqual(model.first, 12)
        XCTAssertEqual(places.bookmark(def.id), 12)
        XCTAssertEqual(places.history(def.id).map(\.ordinal), [1], "only the go(to: 9) jump is in history")
    }

    func testPreviousFromEndReachedByAPlainNextUsesTheUsualRule() async throws {
        let model = try makeModel(Self.wide)
        model.go(to: 10)
        await waitUntil("side by side 10-11") { model.layout == .sideBySide }
        model.next()
        XCTAssertEqual(model.first, 12)
        await waitUntil("strips 10 to 12") { settled(model, [10, 11, 12]) }
        model.previous()
        XCTAssertEqual(model.first, 10, "next then previous returns to the same strip")
    }

    // MARK: Unreadable bookmark

    func testReaderRefusesToOpenWhenTheBookmarkCannotBeRead() async throws {
        places.step(def.id, to: 4)
        try await db.queue.write { try $0.execute(sql: "ALTER TABLE comic RENAME TO comic_gone") }
        XCTAssertThrowsError(try ReaderModel(def: def, library: library, places: places, loader: loader))
        try await db.queue.write { try $0.execute(sql: "ALTER TABLE comic_gone RENAME TO comic") }
        XCTAssertEqual(places.bookmark(def.id), 4, "nothing was written while it could not be read")
    }

    func testFailedStripCanBePassed() async throws {
        let model = try makeModel(Self.narrow)
        model.go(to: 7)
        await waitUntil("strip 7") { settled(model, [7]) }
        XCTAssertEqual(model.strips[7], .failed(canRetry: true))
        model.next()
        XCTAssertEqual(model.first, 8)
    }

    func testFormChangeKeepsFirst() async throws {
        let model = try makeModel(Self.narrow)
        model.go(to: 4)
        await waitUntil("strips 4 and 5") { settled(model, [4, 5]) }
        model.canvas = Self.wide
        model.form = .wide
        XCTAssertEqual(model.first, 4)
        await waitUntil("strips 3 to 6") { settled(model, [3, 4, 5, 6]) }
        XCTAssertEqual(model.first, 4)
    }

    func testTallStripIsSingleInWide() async throws {
        let model = try makeModel(Self.wide)
        model.go(to: 5)
        await waitUntil("strips 5 and 6") { settled(model, [5, 6]) }
        XCTAssertEqual(model.layout, .single)
        model.next()
        XCTAssertEqual(model.first, 6)
    }

    func testBonusImageIsLoaded() async throws {
        let model = try makeModel(Self.narrow)
        model.go(to: 3)
        await waitUntil("strip 3") { settled(model, [3]) }
        guard case .ready(let strip) = model.strips[3] else { return XCTFail("strip 3 not ready") }
        XCTAssertNotNil(strip.bonus)
        XCTAssertEqual(strip.details.hover, "This one has a bonus panel below.")
        XCTAssertEqual(model.entries[3]?.key, "3")
    }

    func testRetryReloadsStrip() async throws {
        let model = try makeModel(Self.narrow)
        await waitUntil("strip 1") { settled(model, [1]) }
        model.retry(1)
        XCTAssertEqual(model.strips[1], .loading)
        await waitUntil("strip 1 again") { settled(model, [1]) }
        guard case .ready = model.strips[1] else { return XCTFail("strip 1 not ready after retry") }
    }

    func testFailedJumpOffersNoBackTarget() async throws {
        let model = try makeModel(Self.narrow)
        try await db.queue.write { try $0.execute(sql: "DROP TABLE jump") }
        model.go(to: 5)
        XCTAssertNil(model.backTarget, "no history row was written, so there is nowhere to go back to")
    }

    func testMissingImageReloadsOnceThenFails() async throws {
        let model = try makeModel(Self.narrow)
        await waitUntil("strip 1") { settled(model, [1]) }
        model.imageMissing(1)
        XCTAssertEqual(model.strips[1], .loading, "the first missing file triggers a reload")
        await waitUntil("strip 1 reloaded") { settled(model, [1]) }
        guard case .ready = model.strips[1] else { return XCTFail("strip 1 not ready after reload") }
        model.imageMissing(1)
        XCTAssertEqual(model.strips[1], .failed(canRetry: true), "a second miss shows the failure card, no loop")
    }

    func testManualRetryStillWorksAfterAutomaticRetry() async throws {
        let model = try makeModel(Self.narrow)
        await waitUntil("strip 1") { settled(model, [1]) }
        model.imageMissing(1)
        await waitUntil("strip 1 reloaded") { settled(model, [1]) }
        model.imageMissing(1)
        model.retry(1)
        await waitUntil("strip 1 after retry") { settled(model, [1]) }
        guard case .ready = model.strips[1] else { return XCTFail("strip 1 not ready after manual retry") }
    }

    func testFailedBookmarkWriteShowsWarning() async throws {
        let model = try makeModel(Self.narrow)
        try await db.queue.write { try $0.execute(sql: "DROP TABLE jump") }
        model.go(to: 5)
        await waitUntil("save warning") { model.saveFailed }
    }
}

/// The bundled fixture site, with a settable latest strip number (to simulate new strips) and an
/// offline switch (every request fails as a transport error).
final class ScriptedFixtureHTTP: HTTPFetching, @unchecked Sendable {
    private let base: FixtureHTTP
    private let lock = NSLock()
    private var _latest: Int?
    private var _offline = false

    init(_ base: FixtureHTTP) { self.base = base }

    var latest: Int? {
        get { lock.withLock { _latest } }
        set { lock.withLock { _latest = newValue } }
    }

    var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        if offline { throw URLError(.notConnectedToInternet) }
        if url.lastPathComponent == "latest.txt", let latest {
            return (Data("\(latest)".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        return try await base.get(url)
    }
}

final class StripSizingTests: XCTestCase {
    private let portrait = CGSize(width: 800, height: 1135)
    private let tall = CGSize(width: 600, height: 3000)

    func testFitWidthShrinksSmallOverflowToFit() {
        let size = StripSizing.size(portrait, box: CGSize(width: 466, height: 610), mode: .fitWidth)
        XCTAssertEqual(size.height, 610, accuracy: 0.5, "661 pt tall is within the slack, so it fits the box")
    }

    func testFitWidthKeepsTallStripFullWidth() {
        let size = StripSizing.size(tall, box: CGSize(width: 466, height: 610), mode: .fitWidth)
        XCTAssertEqual(size.width, 466)
        XCTAssertEqual(size.height, 2330, accuracy: 0.5)
    }

    func testWideSingleFitsPortraitAndWidensTallStrip() {
        let box = CGSize(width: 919, height: 550)
        XCTAssertEqual(StripSizing.size(portrait, box: box, mode: .wideSingle).height, 550, accuracy: 0.5)
        XCTAssertEqual(StripSizing.size(tall, box: box, mode: .wideSingle).width, StripSizing.tallStripWidth)
    }

    func testFitBoxNeverOverflows() {
        let box = CGSize(width: 443, height: 590)
        let size = StripSizing.size(portrait, box: box, mode: .fitBox)
        XCTAssertLessThanOrEqual(size.width, box.width + 0.01)
        XCTAssertLessThanOrEqual(size.height, box.height + 0.01)
    }
}

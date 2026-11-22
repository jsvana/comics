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

    private static let narrow = CGSize(width: 466, height: 678)
    private static let wide = CGSize(width: 951, height: 669)

    override func setUp() async throws {
        let http = try XCTUnwrap(FixtureHTTP.bundled(), "the app bundle has no Fixtures folder")
        let data = try Data(contentsOf: http.root.appendingPathComponent("fixture-catalog.json"))
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

    private func makeModel(_ canvas: CGSize) -> ReaderModel {
        let model = ReaderModel(def: def, library: library, places: places, loader: loader)
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

    func testFixtureComicHasTwelveStrips() {
        let model = makeModel(Self.narrow)
        XCTAssertEqual(model.count, 12)
        XCTAssertEqual(model.first, 1)
    }

    func testNarrowNextMovesOneAndWritesBookmark() async {
        let model = makeModel(Self.narrow)
        await waitUntil("strips 1 and 2") { settled(model, [1, 2]) }
        XCTAssertEqual(model.layout, .single)
        model.next()
        XCTAssertEqual(model.first, 2)
        XCTAssertEqual(places.bookmark(def.id), 2)
    }

    func testWideUsesSideBySideAndMovesByTwo() async {
        let model = makeModel(Self.wide)
        await waitUntil("side by side") { model.layout == .sideBySide }
        model.next()
        XCTAssertEqual(model.first, 3)
        XCTAssertEqual(places.bookmark(def.id), 3)
    }

    func testWideNextThenPreviousReturnsToSameStrip() async {
        let model = makeModel(Self.wide)
        await waitUntil("side by side") { model.layout == .sideBySide }
        model.next()
        await waitUntil("strips 3 and 4") { settled(model, [3, 4]) }
        model.previous()
        XCTAssertEqual(model.first, 1)
        XCTAssertEqual(places.bookmark(def.id), 1)
    }

    func testWidePreviousOverSingleTallStripStepsOne() async {
        let model = makeModel(Self.wide)
        model.go(to: 6)
        await waitUntil("strips 4 to 6") { settled(model, [4, 5, 6]) }
        model.previous()
        XCTAssertEqual(model.first, 5, "4 and 5 do not pair (5 is too tall), so the previous spread is 5 alone")
    }

    func testGoToSetsBackTargetAndGoBackReturns() async {
        let model = makeModel(Self.narrow)
        model.go(to: 9)
        XCTAssertEqual(model.first, 9)
        XCTAssertEqual(model.backTarget, 1)
        XCTAssertEqual(model.history.first?.ordinal, 1)
        model.goBack()
        XCTAssertEqual(model.first, 1)
        XCTAssertNil(model.backTarget)
        XCTAssertEqual(places.bookmark(def.id), 1)
    }

    func testNextClearsBackTarget() async {
        let model = makeModel(Self.narrow)
        model.go(to: 9)
        await waitUntil("strip 9") { settled(model, [9]) }
        model.next()
        XCTAssertEqual(model.first, 10)
        XCTAssertNil(model.backTarget)
    }

    func testNextAtLastStripDoesNothing() async {
        let model = makeModel(Self.narrow)
        model.go(to: 12)
        await waitUntil("strip 12") { settled(model, [12]) }
        XCTAssertTrue(model.atEnd)
        model.next()
        XCTAssertEqual(model.first, 12)
        XCTAssertEqual(places.bookmark(def.id), 12)
    }

    func testWideNextAtFinalPairDoesNothing() async {
        let model = makeModel(Self.wide)
        model.go(to: 11)
        await waitUntil("side by side 11-12") { model.layout == .sideBySide }
        XCTAssertTrue(model.atEnd)
        model.next()
        XCTAssertEqual(model.first, 11)
    }

    func testFailedStripCanBePassed() async {
        let model = makeModel(Self.narrow)
        model.go(to: 7)
        await waitUntil("strip 7") { settled(model, [7]) }
        XCTAssertEqual(model.strips[7], .failed(canRetry: true))
        model.next()
        XCTAssertEqual(model.first, 8)
    }

    func testFormChangeKeepsFirst() async {
        let model = makeModel(Self.narrow)
        model.go(to: 4)
        await waitUntil("strips 4 and 5") { settled(model, [4, 5]) }
        model.canvas = Self.wide
        model.form = .wide
        XCTAssertEqual(model.first, 4)
        await waitUntil("strips 3 to 6") { settled(model, [3, 4, 5, 6]) }
        XCTAssertEqual(model.first, 4)
    }

    func testTallStripIsSingleInWide() async {
        let model = makeModel(Self.wide)
        model.go(to: 5)
        await waitUntil("strips 5 and 6") { settled(model, [5, 6]) }
        XCTAssertEqual(model.layout, .single)
        model.next()
        XCTAssertEqual(model.first, 6)
    }

    func testBonusImageIsLoaded() async {
        let model = makeModel(Self.narrow)
        model.go(to: 3)
        await waitUntil("strip 3") { settled(model, [3]) }
        guard case .ready(let strip) = model.strips[3] else { return XCTFail("strip 3 not ready") }
        XCTAssertNotNil(strip.bonus)
        XCTAssertEqual(strip.details.hover, "This one has a bonus panel below.")
        XCTAssertEqual(model.entries[3]?.key, "3")
    }

    func testRetryReloadsStrip() async {
        let model = makeModel(Self.narrow)
        await waitUntil("strip 1") { settled(model, [1]) }
        model.retry(1)
        XCTAssertEqual(model.strips[1], .loading)
        await waitUntil("strip 1 again") { settled(model, [1]) }
        guard case .ready = model.strips[1] else { return XCTFail("strip 1 not ready after retry") }
    }

    func testFailedBookmarkWriteShowsWarning() async throws {
        let model = makeModel(Self.narrow)
        try await db.queue.write { try $0.execute(sql: "DROP TABLE jump") }
        model.go(to: 5)
        await waitUntil("save warning") { model.saveFailed }
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

import XCTest
import GRDB
@testable import Comics

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { date } }
    func advance(minutes: Double = 0, days: Double = 0) {
        lock.withLock { date = date.addingTimeInterval(minutes * 60 + days * 86_400) }
    }
}

final class LibraryStoreTests: XCTestCase {
    private let latest = "https://stub.test/latest"

    private func numberedDef(skip: [Int] = []) -> ComicDef {
        ComicDef(
            id: "num", title: "Numbered", author: "A", home: URL(string: "https://stub.test/")!, about: "",
            shape: .wide,
            index: .numbered(.init(latestURL: URL(string: latest)!, latestPattern: "\"num\":\\s*(?<n>\\d+)", first: 1, skip: skip)),
            strip: .json(.init(url: "https://stub.test/{key}.json", page: "https://stub.test/{key}", image: "img", title: nil, hover: nil)))
    }

    private func linkListDef() -> ComicDef {
        ComicDef(
            id: "links", title: "Links", author: "A", home: URL(string: "https://stub.test/")!, about: "",
            shape: .wide,
            index: .linkList(.init(url: URL(string: "https://stub.test/archive")!, itemPattern: "<a href=\"/(?<key>\\w+)\">",
                                   pageTemplate: "https://stub.test/{key}", newestFirst: false)),
            strip: .json(.init(url: "https://stub.test/{key}.json", page: "https://stub.test/{key}", image: "img", title: nil, hover: nil)))
    }

    private func serve(_ http: StubHTTP, _ url: String, _ body: String, status: Int = 200) {
        http.routes[url] = (status, [:], Data(body.utf8))
    }

    private func makeStore(_ http: StubHTTP, clock: Clock = Clock()) throws -> (LibraryStore, Comics.Database, Clock) {
        let db = try Comics.Database(path: nil)
        return (LibraryStore(db: db, index: IndexFetcher(http: http), now: { clock.now }), db, clock)
    }

    private func comicRow(_ db: Comics.Database, _ id: String) throws -> ComicRow {
        try XCTUnwrap(try db.queue.read { try ComicRow.fetchOne($0, key: id) })
    }

    func testAddFromFirst() async throws {
        let http = StubHTTP(); serve(http, latest, "{\"num\": 5}")
        let (store, db, _) = try makeStore(http)
        try await store.add(numberedDef(), start: .first, progress: nil)
        XCTAssertEqual(store.count("num"), 5)
        let row = try comicRow(db, "num")
        XCTAssertEqual(row.bookmarkOrdinal, 1)
        XCTAssertEqual(row.bookmarkKey, "1")
        XCTAssertEqual(store.activeIDs(), ["num"])
        XCTAssertEqual(store.definition("num"), numberedDef())
    }

    func testAddFromLatest() async throws {
        let http = StubHTTP(); serve(http, latest, "{\"num\": 5}")
        let (store, db, _) = try makeStore(http)
        try await store.add(numberedDef(), start: .latest, progress: nil)
        let row = try comicRow(db, "num")
        XCTAssertEqual(row.bookmarkOrdinal, 5)
        XCTAssertEqual(row.bookmarkKey, "5")
    }

    func testRefreshAppendsWithoutRenumbering() async throws {
        let http = StubHTTP(); serve(http, latest, "{\"num\": 5}")
        let (store, db, _) = try makeStore(http)
        try await store.add(numberedDef(), start: .first, progress: nil)
        serve(http, latest, "{\"num\": 8}")
        let added = try await store.refresh(numberedDef())
        XCTAssertEqual(added, 3)
        XCTAssertEqual(store.count("num"), 8)
        XCTAssertEqual(store.entry("num", ordinal: 5)?.key, "5")
        XCTAssertEqual(store.ordinal("num", key: "8"), 8)
        XCTAssertEqual(try comicRow(db, "num").bookmarkOrdinal, 1)
    }

    func testRefreshFailureKeepsIndex() async throws {
        let http = StubHTTP(); serve(http, latest, "{\"num\": 5}")
        let (store, db, clock) = try makeStore(http)
        try await store.add(numberedDef(), start: .first, progress: nil)
        let before = try comicRow(db, "num").lastRefreshed
        clock.advance(minutes: 60)
        serve(http, latest, "oops", status: 500)
        do { _ = try await store.refresh(numberedDef()); XCTFail("expected throw") } catch {}
        XCTAssertEqual(store.count("num"), 5)
        XCTAssertEqual(try comicRow(db, "num").lastRefreshed, before)
    }

    func testLinkListLastKeyMissingKeepsIndex() async throws {
        let http = StubHTTP(); serve(http, "https://stub.test/archive", "<a href=\"/a\"><a href=\"/b\"><a href=\"/c\">")
        let (store, db, _) = try makeStore(http)
        try await store.add(linkListDef(), start: .latest, progress: nil)
        XCTAssertEqual(store.count("links"), 3)
        serve(http, "https://stub.test/archive", "<a href=\"/x\"><a href=\"/y\">")
        do { _ = try await store.refresh(linkListDef()); XCTFail("expected throw") } catch {
            XCTAssertEqual(error as? IndexError, .lastKeyMissing)
        }
        XCTAssertEqual(store.count("links"), 3)
        XCTAssertEqual(store.entry("links", ordinal: 3)?.key, "c")
        let row = try comicRow(db, "links")
        XCTAssertEqual(row.bookmarkOrdinal, 3)
        XCTAssertNotNil(row.brokenSince)
    }

    func testStaleRule() async throws {
        let http = StubHTTP(); serve(http, latest, "{\"num\": 5}")
        let (store, _, clock) = try makeStore(http)
        try await store.add(numberedDef(), start: .first, progress: nil)
        let base = http.requested.count
        clock.advance(minutes: 10)
        await store.refreshAllIfStale([numberedDef()], force: false)
        XCTAssertEqual(http.requested.count, base)
        clock.advance(minutes: 21)  // 31 minutes since the add
        await store.refreshAllIfStale([numberedDef()], force: false)
        XCTAssertEqual(http.requested.count, base + 1)
        await store.refreshAllIfStale([numberedDef()], force: false)
        XCTAssertEqual(http.requested.count, base + 1)
        await store.refreshAllIfStale([numberedDef()], force: true)
        XCTAssertEqual(http.requested.count, base + 2)
    }

    func testOneFailureDoesNotStopOthers() async throws {
        let http = StubHTTP(); serve(http, latest, "{\"num\": 2}")
        serve(http, "https://stub.test/archive", "<a href=\"/a\">")
        let (store, _, _) = try makeStore(http)
        try await store.add(linkListDef(), start: .first, progress: nil)
        try await store.add(numberedDef(), start: .first, progress: nil)
        serve(http, "https://stub.test/archive", "", status: 500)
        serve(http, latest, "{\"num\": 4}")
        await store.refreshAllIfStale([linkListDef(), numberedDef()], force: true)
        XCTAssertEqual(store.count("num"), 4)
    }

    func testRemoveKeepsBookmarkFor30Days() async throws {
        let http = StubHTTP(); serve(http, latest, "{\"num\": 5}")
        let (store, db, clock) = try makeStore(http)
        try await store.add(numberedDef(), start: .first, progress: nil)
        try await db.queue.write {
            try $0.execute(sql: "UPDATE comic SET bookmarkOrdinal = 3, bookmarkKey = '3' WHERE id = 'num'")
        }
        store.remove("num")
        XCTAssertEqual(store.activeIDs(), [])
        XCTAssertTrue(store.hasRow("num"))
        clock.advance(days: 29)
        store.purgeRemoved()
        XCTAssertTrue(store.hasRow("num"))
        try await store.add(numberedDef(), start: .first, progress: nil)
        XCTAssertEqual(try comicRow(db, "num").bookmarkOrdinal, 3)
        XCTAssertEqual(store.activeIDs(), ["num"])
    }

    func testPurgeAfter30DaysResetsBookmark() async throws {
        let http = StubHTTP(); serve(http, latest, "{\"num\": 5}")
        let (store, db, clock) = try makeStore(http)
        try await store.add(numberedDef(), start: .first, progress: nil)
        try await db.queue.write {
            try $0.execute(sql: "UPDATE comic SET bookmarkOrdinal = 3, bookmarkKey = '3' WHERE id = 'num'")
        }
        store.remove("num")
        clock.advance(days: 31)
        store.purgeRemoved()
        XCTAssertFalse(store.hasRow("num"))
        XCTAssertEqual(store.count("num"), 0)
        try await store.add(numberedDef(), start: .first, progress: nil)
        XCTAssertEqual(try comicRow(db, "num").bookmarkOrdinal, 1)
        XCTAssertEqual(store.count("num"), 5)
    }

    func testSkipListOrdinals() async throws {
        let http = StubHTTP(); serve(http, latest, "{\"num\": 5}")
        let (store, _, _) = try makeStore(http)
        try await store.add(numberedDef(skip: [3]), start: .first, progress: nil)
        XCTAssertEqual(store.count("num"), 4)
        XCTAssertEqual(store.entry("num", ordinal: 3)?.key, "4")
    }

    func testFileDatabaseReadableFromSecondConnection() async throws {
        let path = NSTemporaryDirectory() + "comics-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let http = StubHTTP(); serve(http, latest, "{\"num\": 5}")
        let first = try Comics.Database(path: path)
        let store = LibraryStore(db: first, index: IndexFetcher(http: http))
        try await store.add(numberedDef(), start: .first, progress: nil)
        let second = try Comics.Database(path: path)
        let n = try await second.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM strip") }
        XCTAssertEqual(n, 5)
        let bookmark = try await second.queue.read { try ComicRow.fetchOne($0, key: "num")?.bookmarkOrdinal }
        XCTAssertEqual(bookmark, 1)
    }

    func testRefreshOfUnknownComicThrows() async throws {
        let (store, _, _) = try makeStore(StubHTTP())
        do { _ = try await store.refresh(numberedDef()); XCTFail("expected throw") } catch {
            XCTAssertEqual(error as? LibraryError, .notInLibrary)
        }
    }

    func testAddRecordsBaseCountOnce() async throws {
        let http = StubHTTP(); serve(http, latest, "{\"num\": 5}")
        let (store, db, _) = try makeStore(http)
        try await store.add(numberedDef(), start: .first, progress: nil)
        XCTAssertEqual(try comicRow(db, "num").baseCount, 5)
        serve(http, latest, "{\"num\": 8}")
        try await store.refresh(numberedDef())
        XCTAssertEqual(try comicRow(db, "num").baseCount, 5)
        store.remove("num")
        try await store.add(numberedDef(), start: .first, progress: nil)  // restored within 30 days
        XCTAssertEqual(try comicRow(db, "num").baseCount, 5)
    }

    func testSummaries() async throws {
        let http = StubHTTP(); serve(http, latest, "{\"num\": 5}")
        serve(http, "https://stub.test/archive", "<a href=\"/a\"><a href=\"/b\">")
        let (store, db, _) = try makeStore(http)
        try await store.add(numberedDef(), start: .first, progress: nil)
        try await store.add(linkListDef(), start: .latest, progress: nil)
        try await db.queue.write {
            try $0.execute(sql: "UPDATE strip SET image = 'https://stub.test/1.png' WHERE comicId = 'num' AND ordinal = 1")
            try $0.execute(sql: "UPDATE comic SET brokenSince = 1 WHERE id = 'links'")
        }
        store.remove("links")
        let all = Dictionary(uniqueKeysWithValues: store.summaries().map { ($0.id, $0) })
        let num = try XCTUnwrap(all["num"])
        XCTAssertEqual(num.def, numberedDef())
        XCTAssertEqual(num.count, 5)
        XCTAssertEqual(num.bookmark, 1)
        XCTAssertEqual(num.baseCount, 5)
        XCTAssertEqual(num.image, URL(string: "https://stub.test/1.png"))
        XCTAssertFalse(num.broken)
        XCTAssertFalse(num.removed)
        let links = try XCTUnwrap(all["links"])
        XCTAssertEqual(links.bookmark, 2)
        XCTAssertNil(links.image)
        XCTAssertTrue(links.broken)
        XCTAssertTrue(links.removed)
    }

    func testAdoptDefinitionsUpdatesOnlyComicsInCatalog() async throws {
        let http = StubHTTP(); serve(http, latest, "{\"num\": 5}")
        serve(http, "https://stub.test/archive", "<a href=\"/a\">")
        let (store, _, _) = try makeStore(http)
        try await store.add(numberedDef(), start: .first, progress: nil)
        try await store.add(linkListDef(), start: .first, progress: nil)
        let renamed = ComicDef(id: "num", title: "Renamed", author: "B", home: URL(string: "https://stub.test/")!, about: "new",
                               shape: .portrait, index: numberedDef().index, strip: numberedDef().strip)
        await store.adoptDefinitions(from: Catalog(schema: 1, version: 2, comics: [renamed]))
        XCTAssertEqual(store.definition("num"), renamed)
        XCTAssertEqual(store.definition("links"), linkListDef(), "a comic that left the catalog keeps its stored definition")
    }
}

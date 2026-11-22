import XCTest
import GRDB
@testable import Comics

final class PlaceKeeperTests: XCTestCase {
    /// Inserts a comic with `count` strips (key = "k<ordinal>") and a bookmark at `bookmark`.
    private func seed(_ db: Comics.Database, id: String = "c", count: Int, bookmark: Int = 1) throws {
        try db.queue.write { dbc in
            try ComicRow(id: id, definition: "{}", addedAt: 0, bookmarkOrdinal: bookmark, bookmarkKey: "k\(bookmark)").insert(dbc)
            for n in 1...count {
                try StripRow(comicId: id, ordinal: n, key: "k\(n)").insert(dbc)
            }
        }
    }

    private func row(_ db: Comics.Database, _ id: String = "c") throws -> ComicRow {
        try XCTUnwrap(try db.queue.read { try ComicRow.fetchOne($0, key: id) })
    }

    private func make(count: Int = 6000, bookmark: Int = 2140) throws -> (PlaceKeeper, Comics.Database) {
        let db = try Comics.Database(path: nil)
        try seed(db, count: count, bookmark: bookmark)
        return (PlaceKeeper(db: db), db)
    }

    func testStepWritesOrdinalAndKey() throws {
        let (keeper, db) = try make()
        keeper.step("c", to: 2141)
        let r = try row(db)
        XCTAssertEqual(r.bookmarkOrdinal, 2141)
        XCTAssertEqual(r.bookmarkKey, "k2141")
        XCTAssertEqual(keeper.bookmark("c"), 2141)
    }

    func testBookmarkVisibleFromSecondConnectionImmediately() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.sqlite").path
        let first = try Comics.Database(path: path)
        try seed(first, count: 20)
        let keeper = PlaceKeeper(db: first)
        keeper.step("c", to: 7)
        let second = try Comics.Database(path: path)  // first is still open: no close, no checkpoint
        XCTAssertEqual(try row(second).bookmarkOrdinal, 7)
        XCTAssertEqual(try row(second).bookmarkKey, "k7")
        withExtendedLifetime(first) {}
    }

    func testJumpPushesHistoryAndBackRestores() throws {
        let (keeper, _) = try make(count: 6000)
        keeper.jump("c", to: 5965)
        XCTAssertEqual(keeper.bookmark("c"), 5965)
        XCTAssertEqual(keeper.history("c").map(\.ordinal), [2140])
        XCTAssertEqual(keeper.history("c").first?.key, "k2140")
        XCTAssertEqual(keeper.back("c"), 2140)
        XCTAssertEqual(keeper.bookmark("c"), 2140)
        XCTAssertTrue(keeper.history("c").isEmpty)
        XCTAssertNil(keeper.back("c"))
        XCTAssertEqual(keeper.bookmark("c"), 2140)
    }

    func testStepDoesNotPushHistory() throws {
        let (keeper, _) = try make()
        keeper.step("c", to: 2141)
        keeper.step("c", to: 2140)
        XCTAssertTrue(keeper.history("c").isEmpty)
    }

    func testHistoryCappedAt10NewestFirst() throws {
        let (keeper, _) = try make(count: 100, bookmark: 1)
        for n in 2...13 { keeper.jump("c", to: n) }  // pushes 1...12
        XCTAssertEqual(keeper.history("c").map(\.ordinal), Array((3...12).reversed()))
        XCTAssertEqual(keeper.back("c"), 12)
    }

    func testClamp() throws {
        let db = try Comics.Database(path: nil)
        try seed(db, count: 10, bookmark: 3)
        let keeper = PlaceKeeper(db: db)
        keeper.jump("c", to: 99999)
        XCTAssertEqual(keeper.bookmark("c"), 10)
        keeper.step("c", to: 0)
        XCTAssertEqual(keeper.bookmark("c"), 1)
        XCTAssertEqual(try row(db).bookmarkKey, "k1")
    }

    func testRestoreSetsBothWithoutPushing() throws {
        let (keeper, _) = try make(count: 100, bookmark: 50)
        let old = [JumpEntry(ordinal: 9, key: "k9", at: Date(timeIntervalSince1970: 2)),
                   JumpEntry(ordinal: 4, key: "k4", at: Date(timeIntervalSince1970: 1))]
        keeper.restore("c", ordinal: 20, history: old)
        XCTAssertEqual(keeper.bookmark("c"), 20)
        XCTAssertEqual(keeper.history("c"), old)
    }

    func testJumpToSamePlaceDoesNotPush() throws {
        let (keeper, _) = try make()
        keeper.jump("c", to: 2140)
        XCTAssertTrue(keeper.history("c").isEmpty)
    }

    func testStatus() {
        XCTAssertEqual(PlaceKeeper.status(bookmark: 5965, count: 5965), .caughtUp)
        XCTAssertEqual(PlaceKeeper.status(bookmark: 5962, count: 5965), .new(3))
        XCTAssertEqual(PlaceKeeper.status(bookmark: 5935, count: 5965), .new(30))
        XCTAssertEqual(PlaceKeeper.status(bookmark: 5934, count: 5965), .behind(at: 5934, of: 5965))
        XCTAssertEqual(PlaceKeeper.status(bookmark: 2140, count: 5965), .behind(at: 2140, of: 5965))
    }

    func testOnChangeFiresOncePerWrite() throws {
        let (keeper, _) = try make()
        var fired: [String] = []
        keeper.onChange = { fired.append($0) }
        keeper.step("c", to: 2141)
        XCTAssertEqual(fired, ["c"])
        keeper.jump("c", to: 5000)
        XCTAssertEqual(fired, ["c", "c"])
        _ = keeper.back("c")
        XCTAssertEqual(fired.count, 3)
        _ = keeper.back("c")  // nothing to pop: no change
        XCTAssertEqual(fired.count, 3)
    }
}

import GRDB
import XCTest
@testable import Comics

final class DatabaseMigrationTests: XCTestCase {
    func testV3BackfillsMissingBaseCount() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).sqlite").path
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        do {
            let db = try Comics.Database(path: path)
            try db.queue.write { d in
                for (id, base) in [("old", nil), ("set", 2)] as [(String, Int?)] {
                    try ComicRow(id: id, definition: "{}", addedAt: 1, baseCount: base).insert(d)
                    for n in 1...5 { try StripRow(comicId: id, ordinal: n, key: "\(n)").insert(d) }
                }
                try ComicRow(id: "empty", definition: "{}", addedAt: 1, baseCount: nil).insert(d)
                // Put the file back to how a v2 install looks: v3 not yet applied.
                try d.execute(sql: "UPDATE comic SET baseCount = NULL WHERE id = 'old'")
                try d.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v3'")
            }
        }
        let db = try Comics.Database(path: path)
        let counts = try db.queue.read { d in
            try Row.fetchAll(d, sql: "SELECT id, baseCount FROM comic ORDER BY id").map { ($0["id"] as String, $0["baseCount"] as Int?) }
        }
        XCTAssertEqual(counts.map(\.0), ["empty", "old", "set"])
        XCTAssertEqual(counts.map(\.1), [0, 5, 2])
    }
}

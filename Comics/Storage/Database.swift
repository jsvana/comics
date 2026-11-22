import Foundation
import GRDB

/// A comic in the library. Times are seconds since 1970. A set `removedAt` means the comic is
/// hidden but its strips and bookmark are kept until `LibraryStore.purgeRemoved()`.
struct ComicRow: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "comic"

    var id: String
    /// The `ComicDef` JSON as of adding or last catalog adoption.
    var definition: String
    var addedAt: Double
    var removedAt: Double?
    var bookmarkOrdinal: Int?
    var bookmarkKey: String?
    var lastRefreshed: Double?
    var brokenSince: Double?
    /// When the reader last opened the comic or moved its bookmark (library sort order).
    var lastReadAt: Double?
    /// Strips in the index when the comic was first added; only strips after these count as "new".
    var baseCount: Int?
}

/// One strip. `ordinal` is 1-based, assigned once on insert and never renumbered.
/// `image`, `hover`, `bonus` and the pixel size are filled in later, when the strip is first loaded.
struct StripRow: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "strip"

    var comicId: String
    var ordinal: Int
    var key: String
    var title: String?
    var date: String?
    var page: String?
    var image: String?
    var hover: String?
    var bonus: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
}

/// A place the reader jumped away from, so it can jump back.
struct JumpRow: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "jump"

    var id: Int64?
    var comicId: String
    var ordinal: Int
    var key: String
    var at: Double

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// SQLite storage. `queue` is a GRDB `DatabaseQueue`: every access is serialised, so a `Database`
/// may be used from any thread. A file-backed database uses the default (non-exclusive) locking,
/// so a second connection on the same file can read committed data immediately.
final class Database: @unchecked Sendable {
    let queue: DatabaseQueue

    /// `path == nil` opens an in-memory database.
    init(path: String?) throws {
        if let path {
            var config = Configuration()
            config.busyMode = .timeout(5)
            queue = try DatabaseQueue(path: path, configuration: config)
        } else {
            queue = try DatabaseQueue()
        }
        try Self.migrator.migrate(queue)
    }

    /// `Application Support/Comics/comics.sqlite`, creating the folder if needed.
    static func defaultPath() throws -> String {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Comics", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("comics.sqlite").path
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "comic") { t in
                t.primaryKey("id", .text)
                t.column("definition", .text).notNull()
                t.column("addedAt", .double).notNull()
                t.column("removedAt", .double)
                t.column("bookmarkOrdinal", .integer)
                t.column("bookmarkKey", .text)
                t.column("lastRefreshed", .double)
                t.column("brokenSince", .double)
            }
            try db.create(table: "strip") { t in
                t.column("comicId", .text).notNull().references("comic", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("key", .text).notNull()
                t.column("title", .text)
                t.column("date", .text)
                t.column("page", .text)
                t.column("image", .text)
                t.column("hover", .text)
                t.column("bonus", .text)
                t.column("pixelWidth", .integer)
                t.column("pixelHeight", .integer)
                t.primaryKey(["comicId", "ordinal"])
                t.uniqueKey(["comicId", "key"])
            }
            try db.create(table: "jump") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("comicId", .text).notNull().references("comic", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("key", .text).notNull()
                t.column("at", .double).notNull()
            }
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "comic") { t in
                t.add(column: "lastReadAt", .double)
                t.add(column: "baseCount", .integer)
            }
        }
        m.registerMigration("v3") { db in
            // v2 left baseCount empty for rows that already existed; give them the comic's current
            // strip count so every row follows the same "new strips" rule.
            try db.execute(sql: """
                UPDATE comic SET baseCount = (SELECT COUNT(*) FROM strip WHERE strip.comicId = comic.id)
                WHERE baseCount IS NULL
                """)
        }
        return m
    }
}

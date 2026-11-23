import Foundation
import GRDB
import os

/// A place the reader jumped away from.
struct JumpEntry: Equatable, Codable {
    let ordinal: Int
    let key: String
    let at: Date
}

/// What a library card says about a comic.
enum CardStatus: Equatable {
    case behind(at: Int, of: Int)
    case new(Int)
    case caughtUp
}

/// Owns the one number that matters per comic: the bookmark. Every change is a small synchronous
/// committed transaction (ordinal and site key together), so a force-quit or crash right after a
/// page turn cannot lose or move the place. Nothing here ever moves a bookmark on its own.
///
/// Thread safety: all state lives in the serialised `Database.queue`; the only other state is
/// `onChange`, which must be set once before use (the cloud mirror does this at start-up).
final class PlaceKeeper: @unchecked Sendable {
    static let historyLimit = 10
    /// At most this many strips to go counts as "new" rather than "behind".
    static let newThreshold = 30

    private let db: Database
    /// Called with the comic id after each committed change, on the calling thread.
    var onChange: ((String) -> Void)?
    /// Called with the error when a write fails (the bookmark was NOT saved). Set once before use.
    var onError: ((Error) -> Void)?

    private static let log = Logger(subsystem: "com.jsvana.comics", category: "place")

    init(db: Database) { self.db = db }

    /// The bookmarked ordinal, or 1 if the comic has none. A read error also gives 1, so never use
    /// this to decide where to write: use `savedBookmark`, which throws instead.
    func bookmark(_ comic: String) -> Int {
        do {
            return try savedBookmark(comic)
        } catch {
            return 1
        }
    }

    /// The bookmarked ordinal, or 1 if the comic has none; throws if it cannot be read, so a caller
    /// never mistakes an unreadable place for the start of the comic.
    func savedBookmark(_ comic: String) throws -> Int {
        do {
            return try db.queue.read { try ComicRow.fetchOne($0, key: comic) }?.bookmarkOrdinal ?? 1
        } catch {
            Self.log.error("bookmark read failed for \(comic, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Next / previous: moves the bookmark without touching history.
    func step(_ comic: String, to ordinal: Int) {
        commit(comic) { dbc in try Self.move(comic, to: ordinal, dbc) != nil }
    }

    /// Scrubber, "go to", "latest": pushes the old position (unless it is the same place), then moves.
    func jump(_ comic: String, to ordinal: Int) {
        commit(comic) { dbc in
            guard let old = try ComicRow.fetchOne(dbc, key: comic),
                  let oldOrdinal = old.bookmarkOrdinal, let oldKey = old.bookmarkKey,
                  let target = try Self.resolve(comic, ordinal, dbc) else {
                return try Self.move(comic, to: ordinal, dbc) != nil
            }
            guard target.ordinal != oldOrdinal else { return false }
            var entry = JumpRow(id: nil, comicId: comic, ordinal: oldOrdinal, key: oldKey, at: Date().timeIntervalSince1970)
            try entry.insert(dbc)
            try dbc.execute(
                sql: """
                DELETE FROM jump WHERE comicId = ? AND id NOT IN
                (SELECT id FROM jump WHERE comicId = ? ORDER BY id DESC LIMIT ?)
                """,
                arguments: [comic, comic, Self.historyLimit])
            return try Self.move(comic, to: target.ordinal, dbc) != nil
        }
    }

    /// Pops the newest history entry and moves there (no new push). Nil if there is none.
    @discardableResult
    func back(_ comic: String) -> Int? {
        var result: Int?
        commit(comic) { dbc in
            guard let top = try JumpRow.filter(Column("comicId") == comic).order(Column("id").desc).fetchOne(dbc) else {
                return false
            }
            // Move first; only pop the entry if the move happened, so history is never lost.
            guard let moved = try Self.move(comic, to: top.ordinal, dbc) else { return false }
            try top.delete(dbc)
            result = moved
            return true
        }
        return result
    }

    /// Newest first.
    func history(_ comic: String) -> [JumpEntry] {
        let rows: [JumpRow]
        do {
            rows = try db.queue.read {
                try JumpRow.filter(Column("comicId") == comic).order(Column("id").desc).fetchAll($0)
            }
        } catch {
            Self.log.error("history read failed for \(comic, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
        return rows.map { JumpEntry(ordinal: $0.ordinal, key: $0.key, at: Date(timeIntervalSince1970: $0.at)) }
    }

    /// Sets bookmark and history together without pushing. `history` is newest first.
    func restore(_ comic: String, ordinal: Int, history: [JumpEntry]) {
        commit(comic) { dbc in
            guard try Self.move(comic, to: ordinal, dbc) != nil else { return false }
            try dbc.execute(sql: "DELETE FROM jump WHERE comicId = ?", arguments: [comic])
            for entry in history.prefix(Self.historyLimit).reversed() {  // oldest first, so ids ascend
                var row = JumpRow(id: nil, comicId: comic, ordinal: entry.ordinal, key: entry.key, at: entry.at.timeIntervalSince1970)
                try row.insert(dbc)
            }
            return true
        }
    }

    /// Records that the comic was opened, for the library's "most recently read" order. No `onChange`.
    func markRead(_ comic: String) {
        do {
            try db.queue.write { dbc in
                try dbc.execute(sql: "UPDATE comic SET lastReadAt = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, comic])
            }
        } catch {
            Self.log.error("lastRead write failed for \(comic, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// "New" means strips that arrived after the comic was first indexed (`baseCount` strips), with
    /// the bookmark past all of those and at most `newThreshold` to go; a backlog is never "new".
    static func status(bookmark: Int, count: Int, baseCount: Int = 0) -> CardStatus {
        let remaining = count - bookmark
        if remaining <= 0 { return .caughtUp }
        if remaining <= newThreshold && bookmark >= baseCount { return .new(remaining) }
        return .behind(at: bookmark, of: count)
    }

    // MARK: Internals

    /// Runs `body` in one committed transaction; fires `onChange` afterwards if it reports a change.
    private func commit(_ comic: String, _ body: @escaping (GRDB.Database) throws -> Bool) {
        do {
            if try db.queue.write(body) { onChange?(comic) }
        } catch {
            Self.log.error("place write failed for \(comic, privacy: .public): \(error.localizedDescription, privacy: .public)")
            onError?(error)
        }
    }

    /// The strip `ordinal` clamped to `1...count`, or nil if the comic has no strips.
    private static func resolve(_ comic: String, _ ordinal: Int, _ dbc: GRDB.Database) throws -> StripRow? {
        guard let count = try Int.fetchOne(dbc, sql: "SELECT MAX(ordinal) FROM strip WHERE comicId = ?", arguments: [comic]) else {
            return nil
        }
        return try StripRow.fetchOne(dbc, key: ["comicId": comic, "ordinal": min(max(ordinal, 1), count)])
    }

    /// Writes the bookmark (ordinal and key) for the clamped ordinal; returns it, or nil if nothing could be written.
    private static func move(_ comic: String, to ordinal: Int, _ dbc: GRDB.Database) throws -> Int? {
        guard let strip = try resolve(comic, ordinal, dbc) else { return nil }
        try dbc.execute(
            sql: "UPDATE comic SET bookmarkOrdinal = ?, bookmarkKey = ?, lastReadAt = ? WHERE id = ?",
            arguments: [strip.ordinal, strip.key, Date().timeIntervalSince1970, comic])
        return strip.ordinal
    }
}

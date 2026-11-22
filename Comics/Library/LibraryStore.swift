import Foundation
import GRDB
import Observation

enum StartPoint { case first, latest }

enum LibraryError: Error, Equatable {
    /// `refresh` was called for a comic that was never added (or has been purged).
    case notInLibrary
}

/// Adds, removes and refreshes comics and answers questions about the stored index.
///
/// Thread safety: the store holds only immutable state plus the serialised `Database.queue`, so it
/// is safe to call from any thread. The async methods do their network, parsing and database work
/// off the main thread (the class is not actor-isolated). The synchronous readers do one small
/// indexed query each; `remove` and `purgeRemoved` are small synchronous writes. `revision` is the
/// only observable state; it is bumped on the main actor after every change so SwiftUI views that
/// read it re-evaluate.
@Observable
final class LibraryStore: @unchecked Sendable {
    static let staleInterval: TimeInterval = 30 * 60
    static let removedRetention: TimeInterval = 30 * 24 * 60 * 60

    @MainActor private(set) var revision = 0

    @ObservationIgnored private let db: Database
    @ObservationIgnored private let index: IndexFetcher
    @ObservationIgnored private let now: () -> Date

    init(db: Database, index: IndexFetcher, now: @escaping () -> Date = Date.init) {
        self.db = db
        self.index = index
        self.now = now
    }

    private func changed() {
        Task { @MainActor in self.revision += 1 }
    }

    // MARK: Changes

    /// Adds `def` to the library, or restores it if it was removed less than 30 days ago (the
    /// bookmark is kept, and strips published since are appended). Throws if the index fails;
    /// nothing is stored in that case.
    func add(_ def: ComicDef, start: StartPoint, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let id = def.id
        let stamp = now()
        let definition = try Self.encode(def)
        // A removed comic older than the retention window counts as purged.
        try await db.queue.write { [self] dbc in
            try purge(dbc, at: stamp)
        }
        let (known, lastKey) = try await db.queue.read { try Self.tail(id, $0) }
        let entries = try await index.newEntries(def.index, knownCount: known, lastKey: lastKey, progress: progress)
        try await db.queue.write { dbc in
            var row = try ComicRow.fetchOne(dbc, key: id) ?? ComicRow(id: id, definition: definition, addedAt: stamp.timeIntervalSince1970)
            row.definition = definition
            row.removedAt = nil
            row.lastRefreshed = stamp.timeIntervalSince1970
            row.brokenSince = nil
            try row.save(dbc)
            if try Self.tail(id, dbc).count == known {  // else a concurrent refresh already appended
                try Self.append(entries, to: id, expectingCount: known, dbc)
            }
            if row.bookmarkOrdinal == nil {
                let (count, _) = try Self.tail(id, dbc)
                let ordinal = start == .first ? 1 : count
                if let strip = try StripRow.fetchOne(dbc, key: ["comicId": id, "ordinal": ordinal]) {
                    row.bookmarkOrdinal = strip.ordinal
                    row.bookmarkKey = strip.key
                    try row.update(dbc)
                }
            }
        }
        changed()
    }

    /// Hides the comic. Its strips and bookmark are kept for 30 days.
    func remove(_ id: String) {
        let stamp = now().timeIntervalSince1970
        try? db.queue.write { dbc in
            try dbc.execute(sql: "UPDATE comic SET removedAt = ? WHERE id = ? AND removedAt IS NULL", arguments: [stamp, id])
        }
        changed()
    }

    /// Deletes comics removed more than 30 days ago, with their strips, bookmark and jumps.
    func purgeRemoved() {
        let stamp = now()
        try? db.queue.write { [self] dbc in try purge(dbc, at: stamp) }
        changed()
    }

    private func purge(_ dbc: GRDB.Database, at stamp: Date) throws {
        try dbc.execute(
            sql: "DELETE FROM comic WHERE removedAt IS NOT NULL AND removedAt <= ?",
            arguments: [stamp.timeIntervalSince1970 - Self.removedRetention])
    }

    /// Fetches strips published since the last refresh and appends them. Returns how many were
    /// added. On any failure the stored index, bookmark and `lastRefreshed` are untouched; an
    /// `IndexError` (the recipe no longer fits the site) also records `brokenSince`.
    @discardableResult
    func refresh(_ def: ComicDef) async throws -> Int {
        let id = def.id
        let stamp = now().timeIntervalSince1970
        guard try await db.queue.read({ try ComicRow.fetchOne($0, key: id) }) != nil else {
            throw LibraryError.notInLibrary
        }
        let (known, lastKey) = try await db.queue.read { try Self.tail(id, $0) }
        let entries: [IndexEntry]
        do {
            entries = try await index.newEntries(def.index, knownCount: known, lastKey: lastKey, progress: nil)
        } catch let error as IndexError {
            try? await db.queue.write { dbc in
                try dbc.execute(sql: "UPDATE comic SET brokenSince = ? WHERE id = ? AND brokenSince IS NULL", arguments: [stamp, id])
            }
            changed()
            throw error
        }
        let added = try await db.queue.write { dbc -> Int in
            guard try Self.tail(id, dbc).count == known else { return 0 }  // a concurrent refresh won
            try Self.append(entries, to: id, expectingCount: known, dbc)
            try dbc.execute(sql: "UPDATE comic SET lastRefreshed = ?, brokenSince = NULL WHERE id = ?", arguments: [stamp, id])
            return entries.count
        }
        if added > 0 { changed() }
        return added
    }

    /// Refreshes each active comic in `defs` that has not been refreshed in 30 minutes (or all of
    /// them if `force`). One comic's failure does not stop the others.
    func refreshAllIfStale(_ defs: [ComicDef], force: Bool) async {
        for def in defs {
            let row = try? await db.queue.read { try ComicRow.fetchOne($0, key: def.id) }
            guard let row, row.removedAt == nil else { continue }
            if !force, let last = row.lastRefreshed, now().timeIntervalSince1970 - last < Self.staleInterval { continue }
            _ = try? await refresh(def)
        }
    }

    // MARK: Queries

    func count(_ id: String) -> Int {
        (try? db.queue.read { try Self.tail(id, $0).count }) ?? 0
    }

    func entry(_ id: String, ordinal: Int) -> IndexEntry? {
        let row = try? db.queue.read { try StripRow.fetchOne($0, key: ["comicId": id, "ordinal": ordinal]) }
        return row.map { IndexEntry(key: $0.key, title: $0.title, date: $0.date, page: $0.page.flatMap { URL(string: $0) }) }
    }

    func ordinal(_ id: String, key: String) -> Int? {
        try? db.queue.read {
            try Int.fetchOne($0, sql: "SELECT ordinal FROM strip WHERE comicId = ? AND key = ?", arguments: [id, key])
        }
    }

    /// Ids of comics in the library (not removed), oldest added first.
    func activeIDs() -> [String] {
        (try? db.queue.read {
            try String.fetchAll($0, sql: "SELECT id FROM comic WHERE removedAt IS NULL ORDER BY addedAt, id")
        }) ?? []
    }

    /// True if a row exists, including a removed comic still inside its 30 days.
    func hasRow(_ id: String) -> Bool {
        (try? db.queue.read { try ComicRow.fetchOne($0, key: id) }) != nil
    }

    func definition(_ id: String) -> ComicDef? {
        guard let json = try? db.queue.read({ try ComicRow.fetchOne($0, key: id)?.definition }) else { return nil }
        return try? JSONDecoder().decode(ComicDef.self, from: Data(json.utf8))
    }

    // MARK: Helpers

    private static func encode(_ def: ComicDef) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(def), as: UTF8.self)
    }

    /// Strip count and the key of the newest strip.
    private static func tail(_ id: String, _ dbc: GRDB.Database) throws -> (count: Int, lastKey: String?) {
        let row = try Row.fetchOne(dbc, sql: "SELECT ordinal, key FROM strip WHERE comicId = ? ORDER BY ordinal DESC LIMIT 1", arguments: [id])
        return (row?["ordinal"] ?? 0, row?["key"])
    }

    /// Appends `entries` after strip number `count`; ordinals continue from there.
    private static func append(_ entries: [IndexEntry], to id: String, expectingCount count: Int, _ dbc: GRDB.Database) throws {
        for (i, e) in entries.enumerated() {
            try StripRow(comicId: id, ordinal: count + i + 1, key: e.key, title: e.title, date: e.date, page: e.page?.absoluteString).insert(dbc)
        }
    }
}

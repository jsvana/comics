import CoreGraphics
import Foundation
import GRDB

struct LoadedStrip: Equatable {
    let ordinal: Int
    let details: StripDetails
    /// A file in the image cache. The cache may evict it later, so a consumer that finds it missing
    /// must treat that as "reload" (`StripLoader.reload`), not as a failure.
    let image: URL
    let bonus: URL?
    let pixelSize: CGSize
}

enum StripState: Equatable {
    case loading
    case ready(LoadedStrip)
    case failed(canRetry: Bool)
}

/// Resolves strips to local image files and reads ahead so the next strip is already there.
///
/// `.loading` is only ever returned for work that was cancelled; `load` retries such work itself,
/// so callers see `.ready` or `.failed`.
actor StripLoader {
    static let behind = 5
    static let brokenThreshold = 3

    private struct Key: Hashable { let comic: String; let ordinal: Int }
    private struct Job { let id: Int; let task: Task<StripState, Never> }

    private let db: Database
    private let library: LibraryStore
    private let extractor: StripExtractor
    private let images: ImageCache
    private let unmetered: @Sendable () -> Bool

    private var jobs: [Key: Job] = [:]
    private var nextJobID = 0
    private var noImageRuns: [String: Int] = [:]
    /// Strips whose read-ahead failed; not retried by `prepare` until the reader asks for them.
    private var failedAhead: Set<Key> = []
    private(set) var lastTransportFailed = false

    init(db: Database, library: LibraryStore, extractor: StripExtractor, images: ImageCache, unmetered: @escaping @Sendable () -> Bool) {
        self.db = db
        self.library = library
        self.extractor = extractor
        self.images = images
        self.unmetered = unmetered
    }

    func isBroken(_ comicID: String) -> Bool {
        let since: Double? = (try? db.queue.read { try Double.fetchOne($0, sql: "SELECT brokenSince FROM comic WHERE id = ?", arguments: [comicID]) }) ?? nil
        return since != nil
    }

    /// Details from the database if stored, else extracted and stored; then the image.
    func load(_ def: ComicDef, ordinal: Int) async -> StripState {
        let key = Key(comic: def.id, ordinal: ordinal)
        failedAhead.remove(key)
        while true {
            let state = await job(for: def, key: key).task.value
            // Work cancelled by `prepare` after we joined it: start again unless we were cancelled too.
            if state == .loading && !Task.isCancelled { continue }
            return state
        }
    }

    /// Starts background loads for the strips after `ordinal` (10, or 20 on unmetered Wi-Fi) and
    /// cancels work outside `ordinal-5 ... ordinal+ahead`. Returns immediately.
    func prepare(_ def: ComicDef, around ordinal: Int) {
        let ahead = unmetered() ? 20 : 10
        let window = (ordinal - Self.behind)...(ordinal + ahead)
        for (key, job) in jobs where key.comic != def.id || !window.contains(key.ordinal) {
            job.task.cancel()
            jobs[key] = nil
        }
        failedAhead = failedAhead.filter { $0.comic == def.id && window.contains($0.ordinal) }
        let last = min(library.count(def.id), ordinal + ahead)
        guard ordinal < last else { return }
        for next in (ordinal + 1)...last {
            let key = Key(comic: def.id, ordinal: next)
            if jobs[key] == nil && !failedAhead.contains(key) { _ = job(for: def, key: key) }
        }
    }

    /// Forgets stored details and the cached images for the strip, then loads it afresh.
    func reload(_ def: ComicDef, ordinal: Int) async -> StripState {
        let key = Key(comic: def.id, ordinal: ordinal)
        if let job = jobs.removeValue(forKey: key) { job.task.cancel() }
        let row = try? await db.queue.read { try StripRow.fetchOne($0, key: ["comicId": def.id, "ordinal": ordinal]) }
        for ref in [row?.image, row?.bonus] {
            if let ref, let url = URL(string: ref) { await images.remove(url, comic: def.id) }
        }
        try? await db.queue.write { dbc in
            try dbc.execute(
                sql: "UPDATE strip SET image = NULL, hover = NULL, bonus = NULL, pixelWidth = NULL, pixelHeight = NULL WHERE comicId = ? AND ordinal = ?",
                arguments: [def.id, ordinal])
        }
        return await load(def, ordinal: ordinal)
    }

    // MARK: Jobs

    private func job(for def: ComicDef, key: Key) -> Job {
        if let existing = jobs[key] { return existing }
        nextJobID += 1
        let id = nextJobID
        let task = Task { [self] () -> StripState in
            let state = await perform(def, key.ordinal)
            finish(key, id: id, state: state)
            return state
        }
        let job = Job(id: id, task: task)
        jobs[key] = job
        return job
    }

    private func finish(_ key: Key, id: Int, state: StripState) {
        if jobs[key]?.id == id { jobs[key] = nil }
        if case .failed = state { failedAhead.insert(key) }
    }

    // MARK: Work

    private func perform(_ def: ComicDef, _ ordinal: Int) async -> StripState {
        let id = def.id
        let stored: StripRow?
        do {
            stored = try await db.queue.read { try StripRow.fetchOne($0, key: ["comicId": id, "ordinal": ordinal]) }
        } catch {
            // GRDB's async read throws CancellationError on a cancelled task; that is not a failure.
            if error is CancellationError || Task.isCancelled { return .loading }
            return .failed(canRetry: false)
        }
        guard let row = stored else { return .failed(canRetry: false) }
        var extracted = false
        var details: StripDetails
        if let ref = row.image, let image = URL(string: ref) {
            details = StripDetails(image: image, title: row.title, hover: row.hover, bonus: row.bonus.flatMap { URL(string: $0) },
                                   page: row.page.flatMap { URL(string: $0) } ?? image)
        } else {
            guard let entry = library.entry(id, ordinal: ordinal) else { return .failed(canRetry: false) }
            do {
                details = try await extractor.details(def.strip, entry: entry)
            } catch {
                return failure(error, comic: id)
            }
            if Task.isCancelled { return .loading }
            extracted = true
            details.title = row.title ?? details.title  // as a later load will read it back
            store(details, id: id, ordinal: ordinal)
        }
        let file: URL
        do {
            file = try await images.file(for: details.image, comic: id)
        } catch {
            return failure(error, comic: id)
        }
        if Task.isCancelled { return .loading }
        guard let size = ImageCache.pixelSize(of: file) else {
            await images.remove(details.image, comic: id)
            return .failed(canRetry: true)
        }
        var bonus: URL?
        if let bonusURL = details.bonus { bonus = try? await images.file(for: bonusURL, comic: id) }
        if Task.isCancelled { return .loading }
        storeSize(size, id: id, ordinal: ordinal)
        lastTransportFailed = false
        if extracted { recordSuccess(id) }
        return .ready(LoadedStrip(ordinal: ordinal, details: details, image: file, bonus: bonus, pixelSize: size))
    }

    /// Synchronous so a cancellation arriving now cannot skip the write.
    private func storeSize(_ size: CGSize, id: String, ordinal: Int) {
        try? db.queue.write { dbc in
            try dbc.execute(sql: "UPDATE strip SET pixelWidth = ?, pixelHeight = ? WHERE comicId = ? AND ordinal = ?",
                            arguments: [Int(size.width), Int(size.height), id, ordinal])
        }
    }

    private func store(_ details: StripDetails, id: String, ordinal: Int) {
        try? db.queue.write { dbc in
            try dbc.execute(
                sql: """
                UPDATE strip SET image = ?, hover = ?, bonus = ?, title = COALESCE(title, ?), page = COALESCE(page, ?)
                WHERE comicId = ? AND ordinal = ?
                """,
                arguments: [details.image.absoluteString, details.hover, details.bonus?.absoluteString,
                            details.title, details.page.absoluteString, id, ordinal])
        }
    }

    /// Maps an error to a state. Cancellation is not a failure. Only `noImage` counts toward broken;
    /// a transport error (anything that is not an HTTP status) drives the offline banner.
    private func failure(_ error: Error, comic: String) -> StripState {
        if error is CancellationError || Task.isCancelled { return .loading }
        switch error {
        case StripError.noImage:
            lastTransportFailed = false
            let run = (noImageRuns[comic] ?? 0) + 1
            noImageRuns[comic] = run
            if run >= Self.brokenThreshold { markBroken(comic) }
        case StripError.http, HTTPError.status:
            lastTransportFailed = false
        case ImageCacheError.emptyBody:
            break
        default:
            lastTransportFailed = true
        }
        return .failed(canRetry: true)
    }

    private func recordSuccess(_ comic: String) {
        noImageRuns[comic] = 0
        try? db.queue.write { dbc in
            try dbc.execute(sql: "UPDATE comic SET brokenSince = NULL WHERE id = ? AND brokenSince IS NOT NULL", arguments: [comic])
        }
    }

    private func markBroken(_ comic: String) {
        let stamp = Date().timeIntervalSince1970
        try? db.queue.write { dbc in
            try dbc.execute(sql: "UPDATE comic SET brokenSince = ? WHERE id = ? AND brokenSince IS NULL", arguments: [stamp, comic])
        }
    }
}

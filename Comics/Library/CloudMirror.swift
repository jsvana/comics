import Foundation

/// A small key-value store that survives a reinstall (iCloud key-value storage in the app).
protocol KeyValueCloud: Sendable {
    func data(forKey: String) -> Data?
    func set(_ data: Data?, forKey: String)
    var allKeys: [String] { get }
    /// Calls `handler`, on any thread, each time the store changes from outside this process (for
    /// example iCloud's first download after an install). Set once, by the cloud mirror.
    func observeExternalChanges(_ handler: @escaping @Sendable () -> Void)
}

/// `NSUbiquitousKeyValueStore` behind `KeyValueCloud`. Payloads here are a few hundred bytes, far
/// below its 1 MB limits.
final class UbiquitousCloud: KeyValueCloud, @unchecked Sendable {
    private let store = NSUbiquitousKeyValueStore.default
    private let lock = NSLock()
    private var observer: NSObjectProtocol?

    init() { store.synchronize() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func data(forKey key: String) -> Data? { store.data(forKey: key) }

    func set(_ data: Data?, forKey key: String) {
        if let data { store.set(data, forKey: key) } else { store.removeObject(forKey: key) }
        store.synchronize()
    }

    var allKeys: [String] { Array(store.dictionaryRepresentation.keys) }

    func observeExternalChanges(_ handler: @escaping @Sendable () -> Void) {
        let token = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: nil
        ) { _ in handler() }
        let old = lock.withLock { () -> NSObjectProtocol? in
            defer { observer = token }
            return observer
        }
        if let old { NotificationCenter.default.removeObserver(old) }
    }
}

/// In-memory stand-in for tests and `-icloud NO`.
final class MemoryCloud: KeyValueCloud, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var externalHandler: (@Sendable () -> Void)?
    private var _onSet: ((String, Data?) -> Void)?

    init() {}

    /// Called after each `set`, on the thread that called it. For tests.
    var onSet: ((String, Data?) -> Void)? {
        get { lock.withLock { _onSet } }
        set { lock.withLock { _onSet = newValue } }
    }

    func data(forKey key: String) -> Data? { lock.withLock { values[key] } }

    func set(_ data: Data?, forKey key: String) {
        lock.withLock { values[key] = data }
        onSet?(key, data)
    }

    var allKeys: [String] { lock.withLock { Array(values.keys) } }

    func observeExternalChanges(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { externalHandler = handler }
    }

    /// Behaves as if iCloud had just delivered changes made elsewhere.
    func simulateExternalChange() {
        lock.withLock { externalHandler }?()
    }
}

/// One comic's place as stored in the cloud and in the progress file. `history` is newest first.
struct SavedPlace: Codable, Equatable {
    let comicID: String
    let ordinal: Int
    let key: String
    let history: [JumpEntry]
    let removed: Bool

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    /// The local state of `id`, or nil if there is no row, the bookmark cannot be read, or there is
    /// no strip to name the bookmark by.
    static func current(_ id: String, library: LibraryStore, places: PlaceKeeper) -> SavedPlace? {
        guard library.hasRow(id), let ordinal = try? places.savedBookmark(id) else { return nil }
        guard let entry = library.entry(id, ordinal: ordinal) else { return nil }
        return SavedPlace(comicID: id, ordinal: ordinal, key: entry.key, history: places.history(id),
                          removed: !library.activeIDs().contains(id))
    }

    /// The ordinal this place has in the comic's current index: where its key lives now, else the
    /// stored ordinal clamped to the index. Nil if the index is empty.
    func resolvedOrdinal(library: LibraryStore) -> Int? {
        resolve(ordinal: ordinal, key: key, library: library)
    }

    /// Adds a comic that has no local row (starting at the first strip), then puts the bookmark and
    /// history where this place says. If the index cannot be fetched nothing is stored and this throws.
    func restoreAsNew(_ def: ComicDef, library: LibraryStore, places: PlaceKeeper) async throws {
        try await library.add(def, start: .first)
        restore(library: library, places: places)
    }

    /// Puts the bookmark and history of the comic (which must have a row) where this place says,
    /// mapped onto its current index. With an empty index nothing changes.
    func restore(library: LibraryStore, places: PlaceKeeper) {
        guard let target = resolvedOrdinal(library: library) else { return }  // empty index: bookmark stays at 1
        let remapped = history.map { entry in
            JumpEntry(ordinal: resolve(ordinal: entry.ordinal, key: entry.key, library: library) ?? entry.ordinal,
                      key: entry.key, at: entry.at)
        }
        places.restore(comicID, ordinal: target, history: remapped)
    }

    private func resolve(ordinal: Int, key: String, library: LibraryStore) -> Int? {
        let count = library.count(comicID)
        guard count > 0 else { return nil }
        return library.ordinal(comicID, key: key) ?? min(max(ordinal, 1), count)
    }
}

/// Keeps a copy of each comic's place in iCloud so a reinstall or a new phone can pick up where
/// the reader was. This is a restore copy for one phone, not sync: it is written on every change
/// and read only for comics with no local row at all (by `restoreMissing`, or when such a comic is
/// added by hand before the restore ran).
///
/// Pushes run on a private serial queue, never on the caller's thread: each reads the comic's
/// state when it runs, so the last write always wins, and pushes for one comic coalesce.
final class CloudMirror: @unchecked Sendable {
    static let keyPrefix = "place."

    private let cloud: KeyValueCloud
    private let library: LibraryStore
    private let places: PlaceKeeper
    private let lock = NSLock()
    private var restoring: Set<String> = []
    private var queued: Set<String> = []
    private var restoreRunning = false
    private var restoreAgain: Catalog?
    private let pushQueue = DispatchQueue(label: "com.jsvana.comics.cloud-push", qos: .utility)
    private let externalChanges: AsyncStream<Void>
    private let externalContinuation: AsyncStream<Void>.Continuation

    /// Hooks `places.onChange` and `library.onChange` so every bookmark move, add and remove pushes,
    /// and listens for changes iCloud delivers (see `followExternalChanges`).
    init(cloud: KeyValueCloud, library: LibraryStore, places: PlaceKeeper) {
        self.cloud = cloud
        self.library = library
        self.places = places
        (externalChanges, externalContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        places.onChange = { [weak self] id in self?.push(id) }
        library.onChange = { [weak self] id, change in self?.libraryChanged(id, change) }
        let continuation = externalContinuation
        cloud.observeExternalChanges { continuation.yield() }
    }

    deinit { externalContinuation.finish() }

    /// Queues a write of `comicID`'s current place to the cloud. The write does nothing if the comic
    /// has no row, its bookmark cannot be read, or it has no strips.
    func push(_ comicID: String) {
        let schedule = lock.withLock { () -> Bool in
            if restoring.contains(comicID) { return false }
            return queued.insert(comicID).inserted
        }
        guard schedule else { return }
        pushQueue.async { [self] in
            let skip = lock.withLock { () -> Bool in
                queued.remove(comicID)
                return restoring.contains(comicID)
            }
            if !skip { write(comicID) }
        }
    }

    /// Waits until every push queued so far has reached the cloud store.
    func flush() {
        pushQueue.sync {}
    }

    /// Runs until cancelled: each time iCloud delivers changes made elsewhere, restores the comics
    /// only the cloud knows (with the catalog `catalog` gives then), then calls `restored`.
    func followExternalChanges(catalog: () async -> Catalog, then restored: () async -> Void) async {
        for await _ in externalChanges {
            await restoreMissing(catalog: await catalog())
            await restored()
        }
    }

    private func write(_ comicID: String) {
        guard let place = SavedPlace.current(comicID, library: library, places: places),
              let data = try? SavedPlace.encoder().encode(place) else { return }
        cloud.set(data, forKey: Self.keyPrefix + comicID)
    }

    private func libraryChanged(_ id: String, _ change: LibraryChange) {
        if change == .added(firstTime: true) { adoptCloudPlace(id) }
        push(id)
    }

    /// `id` was just added with no earlier local record. If the cloud holds a place for it that is
    /// not marked removed, that is the reader's place from before a reinstall (restore had not run
    /// yet, or found nothing): put it back instead of overwriting it with the add's starting strip.
    private func adoptCloudPlace(_ id: String) {
        guard !lock.withLock({ restoring.contains(id) }),
              let data = cloud.data(forKey: Self.keyPrefix + id),
              let place = try? SavedPlace.decoder().decode(SavedPlace.self, from: data),
              place.comicID == id, !place.removed else { return }
        place.restore(library: library, places: places)
    }

    /// Run at launch and when iCloud delivers changes. Acts only on cloud entries that are in
    /// `catalog`, not marked removed, and have no local row at all; it never changes a comic that
    /// exists locally. A comic whose index cannot be fetched is skipped (and tried again next
    /// launch). Calls made while a pass is running run once more after it, not alongside it.
    func restoreMissing(catalog: Catalog) async {
        let start = lock.withLock { () -> Bool in
            if restoreRunning {
                restoreAgain = catalog
                return false
            }
            restoreRunning = true
            return true
        }
        guard start else { return }
        var next: Catalog? = catalog
        while let current = next {
            await restorePass(catalog: current)
            next = lock.withLock {
                defer { restoreAgain = nil }
                if restoreAgain == nil { restoreRunning = false }
                return restoreAgain
            }
        }
    }

    private func restorePass(catalog: Catalog) async {
        let defs = Dictionary(catalog.comics.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for key in cloud.allKeys where key.hasPrefix(Self.keyPrefix) {
            guard let data = cloud.data(forKey: key),
                  let place = try? SavedPlace.decoder().decode(SavedPlace.self, from: data),
                  Self.keyPrefix + place.comicID == key,
                  !place.removed, let def = defs[place.comicID], !library.hasRow(place.comicID) else { continue }
            // Adding writes a start-of-comic bookmark; keep that out of the cloud copy being restored.
            lock.withLock { _ = restoring.insert(place.comicID) }
            try? await place.restoreAsNew(def, library: library, places: places)
            lock.withLock { _ = restoring.remove(place.comicID) }
            push(place.comicID)  // records the restored place (a no-op if nothing was restored)
        }
    }
}

import Foundation

/// A small key-value store that survives a reinstall (iCloud key-value storage in the app).
protocol KeyValueCloud: Sendable {
    func data(forKey: String) -> Data?
    func set(_ data: Data?, forKey: String)
    var allKeys: [String] { get }
}

/// `NSUbiquitousKeyValueStore` behind `KeyValueCloud`. Payloads here are a few hundred bytes, far
/// below its 1 MB limits.
final class UbiquitousCloud: KeyValueCloud, @unchecked Sendable {
    private let store = NSUbiquitousKeyValueStore.default

    init() { store.synchronize() }

    func data(forKey key: String) -> Data? { store.data(forKey: key) }

    func set(_ data: Data?, forKey key: String) {
        if let data { store.set(data, forKey: key) } else { store.removeObject(forKey: key) }
        store.synchronize()
    }

    var allKeys: [String] { Array(store.dictionaryRepresentation.keys) }
}

/// In-memory stand-in for tests and `-icloud NO`.
final class MemoryCloud: KeyValueCloud, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    init() {}

    func data(forKey key: String) -> Data? { lock.withLock { values[key] } }

    func set(_ data: Data?, forKey key: String) {
        lock.withLock { values[key] = data }
    }

    var allKeys: [String] { lock.withLock { Array(values.keys) } }
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

    /// The local state of `id`, or nil if there is no row or no strip to name the bookmark by.
    static func current(_ id: String, library: LibraryStore, places: PlaceKeeper) -> SavedPlace? {
        guard library.hasRow(id) else { return nil }
        let ordinal = places.bookmark(id)
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
/// and read only for comics with no local row at all.
final class CloudMirror: @unchecked Sendable {
    static let keyPrefix = "place."

    private let cloud: KeyValueCloud
    private let library: LibraryStore
    private let places: PlaceKeeper
    private let lock = NSLock()
    private var restoring: Set<String> = []

    /// Hooks `places.onChange` and `library.onChange` so every bookmark move, add and remove pushes.
    init(cloud: KeyValueCloud, library: LibraryStore, places: PlaceKeeper) {
        self.cloud = cloud
        self.library = library
        self.places = places
        places.onChange = { [weak self] id in self?.push(id) }
        library.onChange = { [weak self] id in self?.push(id) }
    }

    /// Writes `comicID`'s current place to the cloud. Does nothing if the comic has no row or no strips.
    func push(_ comicID: String) {
        if lock.withLock({ restoring.contains(comicID) }) { return }
        guard let place = SavedPlace.current(comicID, library: library, places: places),
              let data = try? SavedPlace.encoder().encode(place) else { return }
        cloud.set(data, forKey: Self.keyPrefix + comicID)
    }

    /// Run at launch. Acts only on cloud entries that are in `catalog`, not marked removed, and have
    /// no local row at all; it never changes a comic that exists locally. A comic whose index cannot
    /// be fetched is skipped (and tried again next launch).
    func restoreMissing(catalog: Catalog) async {
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

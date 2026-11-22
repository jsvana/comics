import Foundation

/// The user's explicit "export progress" / "import progress" file: a JSON array of `SavedPlace`.
enum ProgressFile {
    /// Every comic in the library (removed ones are left out).
    static func export(library: LibraryStore, places: PlaceKeeper) throws -> Data {
        let all = library.activeIDs().compactMap { SavedPlace.current($0, library: library, places: places) }
        return try SavedPlace.encoder().encode(all)
    }

    /// Throws if `data` is not a progress file. For a comic already in the library the bookmark is
    /// moved with `jump`, so the old place lands in history; comics not in the library are added
    /// like a restore. Entries marked removed are skipped. Returns, in file order, the ids of comics
    /// that could not be restored: not in the catalog, or their index could not be fetched.
    @discardableResult
    static func apply(_ data: Data, catalog: Catalog, library: LibraryStore, places: PlaceKeeper) async throws -> [String] {
        let list = try SavedPlace.decoder().decode([SavedPlace].self, from: data)
        var failed: [String] = []
        for place in list {
            if library.hasRow(place.comicID) {
                if let target = place.resolvedOrdinal(library: library) { places.jump(place.comicID, to: target) }
                continue
            }
            guard !place.removed else { continue }
            guard let def = catalog.comics.first(where: { $0.id == place.comicID }) else {
                failed.append(place.comicID)
                continue
            }
            do {
                try await place.restoreAsNew(def, library: library, places: places)
            } catch {
                failed.append(place.comicID)
            }
        }
        return failed
    }
}

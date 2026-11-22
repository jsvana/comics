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
    /// like a restore. Comics not in the catalog, and entries marked removed, are skipped.
    static func apply(_ data: Data, catalog: Catalog, library: LibraryStore, places: PlaceKeeper) async throws {
        let list = try SavedPlace.decoder().decode([SavedPlace].self, from: data)
        for place in list {
            guard let def = catalog.comics.first(where: { $0.id == place.comicID }) else { continue }
            if library.hasRow(place.comicID) {
                if let target = place.resolvedOrdinal(library: library) { places.jump(place.comicID, to: target) }
            } else if !place.removed {
                try? await place.restoreAsNew(def, library: library, places: places)
            }
        }
    }
}

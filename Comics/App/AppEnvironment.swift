import Foundation

/// Process-wide configuration and services shared by the app's views.
struct AppEnvironment {
    var launchArgs: LaunchArgs
    let library: LibraryStore
    let places: PlaceKeeper
    /// Keeps the iCloud restore copy current; call `restoreMissing` once at launch.
    let mirror: CloudMirror

    init(launchArgs: LaunchArgs) {
        self.launchArgs = launchArgs
        // Place-keeping is the app's one durable promise: a database that cannot open is fatal,
        // not something to paper over with an in-memory copy.
        let db = try! Database(path: Database.defaultPath())
        library = LibraryStore(db: db, index: IndexFetcher(http: PoliteHTTPClient()))
        places = PlaceKeeper(db: db)
        let cloud: KeyValueCloud = launchArgs.icloud ? UbiquitousCloud() : MemoryCloud()
        mirror = CloudMirror(cloud: cloud, library: library, places: places)
    }

    static let current = AppEnvironment(launchArgs: LaunchArgs(CommandLine.arguments))
}

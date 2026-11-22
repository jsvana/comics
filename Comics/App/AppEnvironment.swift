import Foundation
import Network

/// Process-wide configuration and services shared by the app's views.
///
/// With `-fixtureCatalog YES` (UI tests) the app reads the bundled fixture comic through
/// `FixtureHTTP`, keeps its data in `Application Support/fixture.sqlite` (deleted at launch with
/// `-resetFixture YES`), and uses an in-memory cloud: it never opens the real database or the network.
struct AppEnvironment {
    var launchArgs: LaunchArgs
    let db: Database
    let library: LibraryStore
    let places: PlaceKeeper
    /// Keeps the iCloud restore copy current; call `restoreMissing` once at launch.
    let mirror: CloudMirror
    let loader: StripLoader
    /// Where the catalog comes from: the bundled `catalog.json`, or the fixture catalog.
    private let catalogFile: URL?

    init(launchArgs: LaunchArgs) {
        self.launchArgs = launchArgs
        let http: HTTPFetching
        let dbPath: String
        let imageDir: URL
        let cloud: KeyValueCloud
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        if launchArgs.fixtureCatalog {
            // A build without the fixture folder cannot run fixture mode; failing loudly beats
            // silently reading the real database.
            guard let fixture = FixtureHTTP.bundled() else { fatalError("-fixtureCatalog YES but no bundled Fixtures") }
            http = fixture
            catalogFile = fixture.root.appendingPathComponent("fixture-catalog.json")
            imageDir = caches.appendingPathComponent("FixtureImages", isDirectory: true)
            dbPath = try! Self.fixtureDatabasePath(reset: launchArgs.resetFixture, images: imageDir)
            cloud = MemoryCloud()
        } else {
            http = PoliteHTTPClient()
            catalogFile = Bundle.main.url(forResource: "catalog", withExtension: "json")
            imageDir = caches.appendingPathComponent("Images", isDirectory: true)
            dbPath = try! Database.defaultPath()
            cloud = launchArgs.icloud ? UbiquitousCloud() : MemoryCloud()
        }
        // Place-keeping is the app's one durable promise: a database that cannot open is fatal,
        // not something to paper over with an in-memory copy.
        db = try! Database(path: dbPath)
        library = LibraryStore(db: db, index: IndexFetcher(http: http))
        places = PlaceKeeper(db: db)
        mirror = CloudMirror(cloud: cloud, library: library, places: places)
        let network = launchArgs.fixtureCatalog ? nil : NetworkCost()
        loader = StripLoader(db: db, library: library, extractor: StripExtractor(http: http),
                             images: ImageCache(http: http, directory: imageDir),
                             unmetered: { network?.unmetered ?? false })
    }

    static let current = AppEnvironment(launchArgs: LaunchArgs(CommandLine.arguments))

    /// Reads and decodes the catalog off the main thread.
    func loadCatalog() async throws -> Catalog {
        guard let file = catalogFile else { throw CocoaError(.fileNoSuchFile) }
        return try await Task.detached {
            try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: file))
        }.value
    }

    /// `Application Support/fixture.sqlite`; with `reset`, the old file and fixture images are removed first.
    private static func fixtureDatabasePath(reset: Bool, images: URL) throws -> String {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        let path = dir.appendingPathComponent("fixture.sqlite").path
        if reset {
            for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            try? FileManager.default.removeItem(at: images)
        }
        return path
    }
}

/// Whether the current network is unmetered (not cellular or hotspot, not Low Data Mode), which
/// lets the strip loader read further ahead.
final class NetworkCost: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var value = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let unmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            lock.withLock { self.value = unmetered }
        }
        monitor.start(queue: DispatchQueue(label: "com.jsvana.comics.network-cost"))
    }

    var unmetered: Bool { lock.withLock { value } }
}

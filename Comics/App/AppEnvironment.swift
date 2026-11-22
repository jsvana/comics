import Foundation
import Network

/// Process-wide configuration and services shared by the app's views.
///
/// With `-fixtureCatalog YES` (UI tests) the app reads the bundled fixture comic through
/// `FixtureHTTP`, keeps its data in `Application Support/fixture.sqlite` (deleted at launch with
/// `-resetFixture YES`), and uses an in-memory cloud: it never opens the real database or the network,
/// and the remote catalog is never fetched.
struct AppEnvironment {
    var launchArgs: LaunchArgs
    let db: Database
    let library: LibraryStore
    let places: PlaceKeeper
    /// Keeps the iCloud restore copy current; `restoreMissing` runs whenever the app becomes active.
    let mirror: CloudMirror
    let loader: StripLoader
    let images: ImageCache
    let catalog: CatalogStore
    /// True when the iCloud copy is written to real iCloud (not the in-memory stand-in).
    let usesICloud: Bool

    init(launchArgs: LaunchArgs) {
        self.launchArgs = launchArgs
        let http: HTTPFetching
        let dbPath: String
        let imageDir: URL
        let cloud: KeyValueCloud
        let catalogFile: URL
        let catalogDir: URL
        let remote: URL
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        if launchArgs.fixtureCatalog {
            // A build without the fixture folder cannot run fixture mode; failing loudly beats
            // silently reading the real database.
            guard let fixture = FixtureHTTP.bundled() else { fatalError("-fixtureCatalog YES but no bundled Fixtures") }
            http = fixture
            catalogFile = fixture.root.appendingPathComponent("fixture-catalog.json")
            imageDir = caches.appendingPathComponent("FixtureImages", isDirectory: true)
            catalogDir = support.appendingPathComponent("FixtureCatalog", isDirectory: true)
            dbPath = try! Self.fixtureDatabasePath(reset: launchArgs.resetFixture, images: imageDir, catalog: catalogDir)
            // Served by FixtureHTTP, which has no such file: a refresh is a silent 404, never a request.
            remote = URL(string: "https://\(FixtureHTTP.host)/remote-catalog.json")!
            cloud = MemoryCloud()
            usesICloud = false
        } else {
            http = PoliteHTTPClient()
            guard let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json") else {
                fatalError("catalog.json is missing from the app bundle")
            }
            catalogFile = bundled
            imageDir = caches.appendingPathComponent("Images", isDirectory: true)
            dbPath = try! Database.defaultPath()
            catalogDir = support.appendingPathComponent("Comics", isDirectory: true)
            remote = Self.savedRemote() ?? CatalogStore.defaultRemote
            usesICloud = launchArgs.icloud
            cloud = launchArgs.icloud ? UbiquitousCloud() : MemoryCloud()
        }
        // Place-keeping is the app's one durable promise: a database that cannot open is fatal,
        // not something to paper over with an in-memory copy.
        db = try! Database(path: dbPath)
        let library = LibraryStore(db: db, index: IndexFetcher(http: http))
        self.library = library
        places = PlaceKeeper(db: db)
        mirror = CloudMirror(cloud: cloud, library: library, places: places)
        let network = launchArgs.fixtureCatalog ? nil : NetworkCost()
        images = ImageCache(http: http, directory: imageDir)
        loader = StripLoader(db: db, library: library, extractor: StripExtractor(http: http),
                             images: images, unmetered: { network?.unmetered ?? false })
        // Two small files (the bundled catalog and any adopted copy) are read here, at launch.
        catalog = CatalogStore(bundled: try! Data(contentsOf: catalogFile), http: http, storage: catalogDir, remote: remote)
        catalog.onAdopt = { adopted in await library.adoptDefinitions(from: adopted) }
    }

    static let current = AppEnvironment(launchArgs: LaunchArgs(CommandLine.arguments))

    /// The catalog URL chosen in Settings, if any.
    static func savedRemote() -> URL? {
        UserDefaults.standard.string(forKey: CatalogStore.remoteDefaultsKey).flatMap(URL.init(string:))
    }

    /// Run whenever the app becomes active: drop comics removed over 30 days ago, check the remote
    /// catalog (at most daily), restore comics that only the iCloud copy knows, and look for new
    /// strips in comics not refreshed in the last 30 minutes. Each step is quiet on failure.
    func becameActive() async {
        let library = library
        await Task.detached { library.purgeRemoved() }.value
        async let catalogChecked = refreshCatalog(force: false)
        await mirror.restoreMissing(catalog: catalog.catalog)
        await refreshLibrary(force: false)
        _ = await catalogChecked
    }

    /// Checks the remote catalog (daily, or now with `force`). Never in fixture mode.
    @discardableResult
    func refreshCatalog(force: Bool) async -> CatalogStore.RefreshOutcome {
        guard !launchArgs.fixtureCatalog else { return .notDue }
        return await catalog.refreshIfDue(force: force)
    }

    /// Looks for new strips in every library comic, using each comic's stored definition (so a
    /// comic that has left the catalog still refreshes).
    func refreshLibrary(force: Bool) async {
        let library = library
        let defs = await Task.detached {
            library.summaries().filter { !$0.removed }.compactMap(\.def)
        }.value
        await library.refreshAllIfStale(defs, force: force)
    }

    /// `Application Support/fixture.sqlite`; with `reset`, the old file, fixture images and the
    /// fixture catalog folder are removed first.
    private static func fixtureDatabasePath(reset: Bool, images: URL, catalog: URL) throws -> String {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        let path = dir.appendingPathComponent("fixture.sqlite").path
        if reset {
            for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            try? FileManager.default.removeItem(at: images)
            try? FileManager.default.removeItem(at: catalog)
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

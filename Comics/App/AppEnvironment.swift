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
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let support = try! FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        if launchArgs.fixtureCatalog {
            // A build without the fixture folder cannot run fixture mode; failing loudly beats
            // silently reading the real database.
            guard let fixture = FixtureHTTP.bundled() else { fatalError("-fixtureCatalog YES but no bundled Fixtures") }
            let imageDir = caches.appendingPathComponent("FixtureImages", isDirectory: true)
            let catalogDir = support.appendingPathComponent("FixtureCatalog", isDirectory: true)
            let dbPath = try! Self.fixtureDatabasePath(reset: launchArgs.resetFixture, images: imageDir, catalog: catalogDir)
            self.init(
                launchArgs: launchArgs, http: fixture,
                // Place-keeping is the app's one durable promise: a database that cannot open is fatal,
                // not something to paper over with an in-memory copy.
                db: try! Database(path: dbPath), imageDir: imageDir, cloud: MemoryCloud(), usesICloud: false,
                // Two small files (the bundled catalog and any adopted copy) are read here, at launch.
                bundledCatalog: try! Data(contentsOf: fixture.root.appendingPathComponent("fixture-catalog.json")),
                catalogDir: catalogDir,
                // Served by FixtureHTTP, which has no such file: a refresh is a silent 404, never a request.
                remote: URL(string: "https://\(FixtureHTTP.host)/remote-catalog.json")!,
                network: nil)
        } else {
            guard let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json") else {
                fatalError("catalog.json is missing from the app bundle")
            }
            self.init(
                launchArgs: launchArgs, http: PoliteHTTPClient(),
                db: try! Database(path: try! Database.defaultPath()),
                imageDir: caches.appendingPathComponent("Images", isDirectory: true),
                cloud: launchArgs.icloud ? UbiquitousCloud() : MemoryCloud(), usesICloud: launchArgs.icloud,
                bundledCatalog: try! Data(contentsOf: bundled),
                catalogDir: support.appendingPathComponent("Comics", isDirectory: true),
                remote: Self.savedRemote() ?? CatalogStore.defaultRemote,
                network: NetworkCost())
        }
    }

    /// Wires the services together from their parts (tests pass stubs and in-memory storage).
    init(launchArgs: LaunchArgs, http: HTTPFetching, db: Database, imageDir: URL, cloud: KeyValueCloud,
         usesICloud: Bool, bundledCatalog: Data, catalogDir: URL, remote: URL, network: NetworkCost?) {
        self.launchArgs = launchArgs
        self.db = db
        self.usesICloud = usesICloud
        let library = LibraryStore(db: db, index: IndexFetcher(http: http))
        self.library = library
        places = PlaceKeeper(db: db)
        mirror = CloudMirror(cloud: cloud, library: library, places: places)
        images = ImageCache(http: http, directory: imageDir)
        loader = StripLoader(db: db, library: library, extractor: StripExtractor(http: http),
                             images: images, unmetered: { network?.unmetered ?? false })
        catalog = CatalogStore(bundled: bundledCatalog, http: http, storage: catalogDir, remote: remote)
        catalog.onAdopt = { adopted in await library.adoptDefinitions(from: adopted) }
    }

    static let current = AppEnvironment(launchArgs: LaunchArgs(CommandLine.arguments))

    /// The catalog URL chosen in Settings, if any.
    static func savedRemote() -> URL? {
        UserDefaults.standard.string(forKey: CatalogStore.remoteDefaultsKey).flatMap(CatalogStore.parseRemote)
    }

    /// Remembers the catalog address chosen in Settings (nil goes back to the default). Never in
    /// fixture mode: its `fixture.invalid` address must not reach the real app's settings.
    static func persistRemote(_ url: URL?, fixtureMode: Bool, defaults: UserDefaults = .standard) {
        guard !fixtureMode else { return }
        if let url, url != CatalogStore.defaultRemote {
            defaults.set(url.absoluteString, forKey: CatalogStore.remoteDefaultsKey)
        } else {
            defaults.removeObject(forKey: CatalogStore.remoteDefaultsKey)
        }
    }

    /// Run whenever the app becomes active: drop comics removed over 30 days ago, check the remote
    /// catalog (at most daily), restore comics that only the iCloud copy knows, and look for new
    /// strips in comics not refreshed in the last 30 minutes. Each step is quiet on failure.
    func becameActive() async {
        let library = library
        let catalogStore = catalog
        let mirror = mirror
        await Self.activate(
            purge: { await Task.detached { library.purgeRemoved() }.value },
            checkCatalog: { await refreshCatalog(force: false) },
            currentCatalog: { await MainActor.run { catalogStore.catalog } },
            restore: { await mirror.restoreMissing(catalog: $0) },
            refreshLibrary: { await refreshLibrary(force: false) })
    }

    /// The steps of `becameActive`, in order. The catalog is read (on the main actor, where it
    /// changes) after the remote check has finished, so a comic the new catalog adds can be restored.
    static func activate(
        purge: () async -> Void,
        checkCatalog: () async -> Void,
        currentCatalog: () async -> Catalog,
        restore: (Catalog) async -> Void,
        refreshLibrary: () async -> Void
    ) async {
        await purge()
        await checkCatalog()
        await restore(await currentCatalog())
        await refreshLibrary()
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

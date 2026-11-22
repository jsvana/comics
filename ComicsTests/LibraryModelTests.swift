import XCTest
@testable import Comics

/// Counts requests made through a wrapped fetcher.
private final class CountingHTTP: HTTPFetching, @unchecked Sendable {
    private let inner: HTTPFetching
    private let lock = NSLock()
    private var urls: [URL] = []

    init(_ inner: HTTPFetching) { self.inner = inner }

    var requested: [URL] { lock.withLock { urls } }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { urls.append(url) }
        return try await inner.get(url)
    }
}

/// `LibraryModel` against the bundled fixture comic, with in-memory storage.
@MainActor
final class LibraryModelTests: XCTestCase {
    private var dir: URL!
    private var http: CountingHTTP!
    private var env: AppEnvironment!
    private var model: LibraryModel!
    private var def: ComicDef!

    override func setUp() async throws {
        let fixture = try XCTUnwrap(FixtureHTTP.bundled(), "the app bundle has no Fixtures folder")
        let catalogData = try Data(contentsOf: fixture.root.appendingPathComponent("fixture-catalog.json"))
        def = try XCTUnwrap(JSONDecoder().decode(Catalog.self, from: catalogData).comics.first { $0.id == "fixture" })
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("librarymodel-\(UUID().uuidString)")
        http = CountingHTTP(fixture)
        env = AppEnvironment(
            launchArgs: LaunchArgs(["-fixtureCatalog", "YES"]), http: http, db: try Comics.Database(path: nil),
            imageDir: dir.appendingPathComponent("images"), cloud: MemoryCloud(), usesICloud: false,
            bundledCatalog: catalogData, catalogDir: dir.appendingPathComponent("catalog"),
            remote: URL(string: "https://\(FixtureHTTP.host)/remote-catalog.json")!, network: nil)
        model = LibraryModel(env: env)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    func testThumbnailsNeverFetch() async throws {
        try await env.library.add(def, start: .first)
        await model.reload()
        let before = http.requested.count
        await model.loadThumbnails()
        XCTAssertEqual(http.requested.count, before, "showing the library must not fetch")
        XCTAssertNil(model.thumbnails[def.id], "a comic whose strip was never loaded keeps the placeholder")
    }

    func testThumbnailComesFromCachedImage() async throws {
        try await env.library.add(def, start: .first)
        guard case .ready = await env.loader.load(def, ordinal: 1) else { return XCTFail("strip 1 did not load") }
        await model.reload()
        let before = http.requested.count
        await model.loadThumbnails()
        XCTAssertEqual(http.requested.count, before, "the image was already cached")
        XCTAssertNotNil(model.thumbnails[def.id])
    }

    func testThumbnailMissingFromCacheStaysPlaceholderWithoutFetching() async throws {
        try await env.library.add(def, start: .first)
        guard case .ready = await env.loader.load(def, ordinal: 1) else { return XCTFail("strip 1 did not load") }
        await env.images.clear()
        await model.reload()
        let before = http.requested.count
        await model.loadThumbnails()
        XCTAssertEqual(http.requested.count, before)
        XCTAssertNil(model.thumbnails[def.id])
    }

    func testAddingFlagOutlivesTheReload() async throws {
        model.add(def, start: .first)
        XCTAssertNotNil(model.adding[def.id])
        // The progress row may only go away once the comic is in `rows`; otherwise the catalog row
        // would briefly show "Add" again.
        let deadline = Date().addingTimeInterval(10)
        while model.rows[def.id] == nil, Date() < deadline {
            XCTAssertNotNil(model.adding[def.id], "adding cleared before the library reloaded")
            await Task.yield()
        }
        XCTAssertNotNil(model.rows[def.id])
        await waitUntil("add to finish") { model.adding[def.id] == nil }
        XCTAssertEqual(model.cards.map(\.id), [def.id])
    }
}

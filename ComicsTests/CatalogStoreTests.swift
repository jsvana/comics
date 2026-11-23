import XCTest
@testable import Comics

final class CatalogStoreTests: XCTestCase {
    private let remote = URL(string: "https://stub.test/catalog.json")!
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appendingPathComponent("CatalogStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storage)
    }

    private func comic(_ id: String, title: String = "T") -> ComicDef {
        ComicDef(
            id: id, title: title, author: "A", home: URL(string: "https://stub.test/")!, about: "",
            shape: .wide,
            index: .numbered(.init(latestURL: URL(string: "https://stub.test/latest")!, latestPattern: "(?<n>\\d+)", first: 1, skip: [])),
            strip: .json(.init(url: "https://stub.test/{key}.json", page: "https://stub.test/{key}", image: "img", title: nil, hover: nil)))
    }

    private func json(schema: Int = 1, version: Int, ids: [String]) throws -> Data {
        try JSONEncoder().encode(Catalog(schema: schema, version: version, comics: ids.map { comic($0) }))
    }

    private func make(_ http: StubHTTP, now: @escaping () -> Date = Date.init) throws -> CatalogStore {
        CatalogStore(bundled: try json(version: 1, ids: ["a"]), http: http, storage: storage, remote: remote, now: now)
    }

    private func serve(_ http: StubHTTP, _ body: Data) {
        http.routes[remote.absoluteString] = (200, [:], body)
    }

    func testStartsWithBundled() throws {
        let store = try make(StubHTTP())
        XCTAssertEqual(store.catalog.version, 1)
        XCTAssertEqual(store.catalog.comics.map(\.id), ["a"])
    }

    func testAdoptsNewerRemote() async throws {
        let http = StubHTTP()
        serve(http, try json(version: 2, ids: ["a", "b"]))
        let store = try make(http)
        let outcome = await store.refreshIfDue(force: false)
        XCTAssertEqual(outcome, .adopted)
        XCTAssertEqual(store.catalog.version, 2)
        XCTAssertEqual(store.catalog.comics.map(\.id), ["a", "b"])
    }

    func testRejectsLowerVersion() async throws {
        let http = StubHTTP()
        serve(http, try json(version: 0, ids: ["z"]))
        let store = try make(http)
        await store.refreshIfDue(force: false)
        XCTAssertEqual(store.catalog.version, 1)
        XCTAssertEqual(store.catalog.comics.map(\.id), ["a"])
    }

    func testRejectsUnknownSchema() async throws {
        let http = StubHTTP()
        serve(http, try json(schema: 2, version: 5, ids: ["z"]))
        let store = try make(http)
        await store.refreshIfDue(force: false)
        XCTAssertEqual(store.catalog.version, 1)
        XCTAssertEqual(store.catalog.comics.map(\.id), ["a"])
    }

    func testRejectsInvalidJSON() async throws {
        let http = StubHTTP()
        serve(http, Data("{\"schema\": 1, \"version\": 9, \"comics\": [{\"id\": 3}]}".utf8))
        let store = try make(http)
        await store.refreshIfDue(force: false)
        XCTAssertEqual(store.catalog.version, 1)
        XCTAssertEqual(store.catalog.comics.map(\.id), ["a"])
    }

    func testSecondRefreshWithin24HoursMakesNoRequest() async throws {
        let http = StubHTTP()
        serve(http, try json(version: 2, ids: ["a"]))
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try make(http, now: { clock })
        await store.refreshIfDue(force: false)
        XCTAssertEqual(http.requested.count, 1)
        clock = clock.addingTimeInterval(23 * 3600)
        let outcome = await store.refreshIfDue(force: false)
        XCTAssertEqual(outcome, .notDue)
        XCTAssertEqual(http.requested.count, 1)
        await store.refreshIfDue(force: true)
        XCTAssertEqual(http.requested.count, 2)
        clock = clock.addingTimeInterval(25 * 3600)
        await store.refreshIfDue(force: false)
        XCTAssertEqual(http.requested.count, 3)
    }

    func testLastCheckSurvivesNewStore() async throws {
        let http = StubHTTP()
        serve(http, try json(version: 2, ids: ["a"]))
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        try await make(http, now: { clock }).refreshIfDue(force: false)
        let again = try make(http, now: { clock.addingTimeInterval(3600) })
        await again.refreshIfDue(force: false)
        XCTAssertEqual(http.requested.count, 1)
    }

    func testAdoptedCopySurvivesNewStore() async throws {
        let http = StubHTTP()
        serve(http, try json(version: 2, ids: ["a", "b"]))
        try await make(http).refreshIfDue(force: false)
        let again = try make(StubHTTP())
        XCTAssertEqual(again.catalog.version, 2)
        XCTAssertEqual(again.catalog.comics.map(\.id), ["a", "b"])
    }

    func testBundledWinsOverOlderSavedCopy() async throws {
        let http = StubHTTP()
        serve(http, try json(version: 2, ids: ["a", "b"]))
        try await make(http).refreshIfDue(force: false)
        let newerApp = CatalogStore(bundled: try json(version: 3, ids: ["a", "c"]), http: StubHTTP(), storage: storage, remote: remote)
        XCTAssertEqual(newerApp.catalog.version, 3)
    }

    func testHTTPFailureLeavesCatalogUnchanged() async throws {
        let http = StubHTTP()
        http.failure = URLError(.notConnectedToInternet)
        let store = try make(http)
        let outcome = await store.refreshIfDue(force: false)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(store.catalog.version, 1)

        let missing = try make(StubHTTP())  // 404, as while the remote file does not exist
        let notFound = await missing.refreshIfDue(force: true)
        XCTAssertEqual(notFound, .failed)
        XCTAssertEqual(missing.catalog.version, 1)
    }

    func testTransportFailureIsNotRecordedAsACheck() async throws {
        let http = StubHTTP()
        http.failure = URLError(.notConnectedToInternet)
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try make(http, now: { clock })
        let offline = await store.refreshIfDue(force: false)
        XCTAssertEqual(offline, .failed)
        http.failure = nil
        serve(http, try json(version: 2, ids: ["a"]))
        let online = await store.refreshIfDue(force: false)
        XCTAssertEqual(online, .adopted, "an offline first launch tries again at the next activation")
        XCTAssertEqual(http.requested.count, 2)
        let restarted = try make(http, now: { clock })
        let again = await restarted.refreshIfDue(force: false)
        XCTAssertEqual(again, .notDue, "the successful check was recorded")
    }

    func testHTTPStatusFailureIsRecordedAsACheck() async throws {
        let http = StubHTTP()  // 404, as while the remote file does not exist
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try make(http, now: { clock })
        let first = await store.refreshIfDue(force: false)
        XCTAssertEqual(first, .failed)
        let second = await store.refreshIfDue(force: false)
        XCTAssertEqual(second, .notDue)
        XCTAssertEqual(http.requested.count, 1)
    }

    func testAdoptionCallsHook() async throws {
        let http = StubHTTP()
        serve(http, try json(version: 2, ids: ["a", "b"]))
        let store = try make(http)
        let seen = Locked<[Int]>([])
        store.onAdopt = { catalog in seen.mutate { $0.append(catalog.version) } }
        await store.refreshIfDue(force: false)
        XCTAssertEqual(seen.value, [2])
    }

    func testRemoteCanBeChanged() async throws {
        let http = StubHTTP()
        let other = URL(string: "https://stub.test/other.json")!
        http.routes[other.absoluteString] = (200, [:], try json(version: 4, ids: ["a"]))
        let store = try make(http)
        store.remote = other
        await store.refreshIfDue(force: true)
        XCTAssertEqual(store.catalog.version, 4)
        XCTAssertEqual(http.requested, [other])
    }
}

/// A value shared with a `@Sendable` closure in tests.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.withLock { _value } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&_value) } }
}

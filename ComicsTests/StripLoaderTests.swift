import GRDB
import XCTest
@testable import Comics

final class StripLoaderTests: XCTestCase {
    private var dir: URL!
    private var http: StubHTTP!
    private var db: Comics.Database!
    private var unmetered: UnmeteredFlag!

    private final class UnmeteredFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isOn: Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
    }

    private let def = ComicDef(
        id: "num", title: "Numbered", author: "A", home: URL(string: "https://stub.test/")!, about: "",
        shape: .wide,
        index: .numbered(.init(latestURL: URL(string: "https://stub.test/latest")!, latestPattern: "(?<n>\\d+)", first: 1, skip: [])),
        strip: .json(.init(url: "https://stub.test/{key}.json", page: "https://stub.test/{key}", image: "img", title: nil, hover: nil)))

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("striploader-\(UUID().uuidString)")
        http = StubHTTP()
        unmetered = UnmeteredFlag()
        db = try Comics.Database(path: nil)
        try await db.queue.write { dbc in
            try ComicRow(id: "num", definition: "{}", addedAt: 0).insert(dbc)
            for n in 1...40 { try StripRow(comicId: "num", ordinal: n, key: "\(n)", title: "T\(n)", date: nil, page: nil).insert(dbc) }
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeLoader() -> StripLoader {
        let flag = unmetered!
        return StripLoader(
            db: db, library: LibraryStore(db: db, index: IndexFetcher(http: http)), extractor: StripExtractor(http: http),
            images: ImageCache(http: http, directory: dir), unmetered: { flag.isOn })
    }

    private func serveStrip(_ n: Int) {
        http.routes["https://stub.test/\(n).json"] = (200, [:], Data("{\"img\": \"https://img.test/\(n).png\"}".utf8))
        http.routes["https://img.test/\(n).png"] = (200, [:], ImageCacheTests.png(width: 30, height: 20))
    }

    private func serveNoImage(_ n: Int) {
        http.routes["https://stub.test/\(n).json"] = (200, [:], Data("{}".utf8))
    }

    private func detailRequests() -> Set<Int> {
        Set(http.requested.compactMap { url -> Int? in
            guard url.host == "stub.test", url.path.hasSuffix(".json") else { return nil }
            return Int(url.deletingPathExtension().lastPathComponent)
        })
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    func testLoadTwiceExtractsOnceAndStoresSize() async throws {
        serveStrip(1)
        let loader = makeLoader()
        let first = await loader.load(def, ordinal: 1)
        let second = await loader.load(def, ordinal: 1)
        XCTAssertEqual(first, second)
        guard case .ready(let strip) = first else { return XCTFail("expected ready, got \(first)") }
        XCTAssertEqual(strip.pixelSize, CGSize(width: 30, height: 20))
        XCTAssertEqual(strip.details.image.absoluteString, "https://img.test/1.png")
        XCTAssertEqual(http.requested.filter { $0.path.hasSuffix(".json") }.count, 1)
        XCTAssertEqual(http.requested.filter { $0.path.hasSuffix(".png") }.count, 1)
        let row = try await db.queue.read { try StripRow.fetchOne($0, key: ["comicId": "num", "ordinal": 1]) }
        XCTAssertEqual(row?.pixelWidth, 30)
        XCTAssertEqual(row?.pixelHeight, 20)
        XCTAssertEqual(row?.image, "https://img.test/1.png")
    }

    func testConcurrentLoadsShareOneRequest() async throws {
        serveStrip(2)
        let loader = makeLoader()
        async let a = loader.load(def, ordinal: 2)
        async let b = loader.load(def, ordinal: 2)
        let (x, y) = await (a, b)
        XCTAssertEqual(x, y)
        XCTAssertEqual(http.requested.filter { $0.path.hasSuffix(".json") }.count, 1)
    }

    func testPrepareReadsAheadTenWhenMetered() async throws {
        for n in 1...40 { serveStrip(n) }
        let loader = makeLoader()
        await loader.prepare(def, around: 10)
        await waitUntil("11...20") { detailRequests().isSuperset(of: Set(11...20)) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(detailRequests().contains(21))
    }

    func testPrepareReadsAheadTwentyWhenUnmetered() async throws {
        for n in 1...40 { serveStrip(n) }
        unmetered.isOn = true
        let loader = makeLoader()
        await loader.prepare(def, around: 10)
        await waitUntil("11...30") { detailRequests().isSuperset(of: Set(11...30)) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(detailRequests().contains(31))
    }

    func testPrepareStopsAtLastStrip() async throws {
        for n in 1...40 { serveStrip(n) }
        let loader = makeLoader()
        await loader.prepare(def, around: 38)
        await waitUntil("39, 40") { detailRequests().isSuperset(of: [39, 40]) }
        XCTAssertFalse(detailRequests().contains(41))
    }

    func testLoadJoinsPreparedWork() async throws {
        for n in 1...20 { serveStrip(n) }
        let loader = makeLoader()
        await loader.prepare(def, around: 1)
        let state = await loader.load(def, ordinal: 2)
        guard case .ready = state else { return XCTFail("expected ready, got \(state)") }
        XCTAssertEqual(http.requested.filter { $0.path == "/2.json" }.count, 1)
    }

    func testThreeNoImagesMarkBrokenAndSuccessClears() async throws {
        for n in 1...3 { serveNoImage(n) }
        serveStrip(4)
        let loader = makeLoader()
        for n in 1...2 {
            let state = await loader.load(def, ordinal: n)
            XCTAssertEqual(state, .failed(canRetry: true))
        }
        var broken = await loader.isBroken("num")
        XCTAssertFalse(broken)
        _ = await loader.load(def, ordinal: 3)
        broken = await loader.isBroken("num")
        XCTAssertTrue(broken)
        let since = try await db.queue.read { try ComicRow.fetchOne($0, key: "num")?.brokenSince }
        XCTAssertNotNil(since)
        _ = await loader.load(def, ordinal: 4)
        broken = await loader.isBroken("num")
        XCTAssertFalse(broken)
    }

    func testSuccessBetweenNoImagesResetsTheRun() async throws {
        serveNoImage(1); serveNoImage(2); serveStrip(3); serveNoImage(4)
        let loader = makeLoader()
        _ = await loader.load(def, ordinal: 1)
        _ = await loader.load(def, ordinal: 2)
        _ = await loader.load(def, ordinal: 3)
        _ = await loader.load(def, ordinal: 4)
        let broken = await loader.isBroken("num")
        XCTAssertFalse(broken)
    }

    func testHTTPErrorsNeverCountAsBroken() async throws {
        let loader = makeLoader()  // nothing routed: every request is a 404
        for n in 1...3 {
            let state = await loader.load(def, ordinal: n)
            XCTAssertEqual(state, .failed(canRetry: true))
        }
        let broken = await loader.isBroken("num")
        XCTAssertFalse(broken)
        let transport = await loader.lastTransportFailed
        XCTAssertFalse(transport)
    }

    func testImageStatusErrorFailsWithoutBroken() async throws {
        http.routes["https://stub.test/1.json"] = (200, [:], Data("{\"img\": \"https://img.test/1.png\"}".utf8))
        let loader = makeLoader()
        let state = await loader.load(def, ordinal: 1)
        XCTAssertEqual(state, .failed(canRetry: true))
        let broken = await loader.isBroken("num")
        XCTAssertFalse(broken)
    }

    func testReloadRequestsAgain() async throws {
        serveStrip(1)
        let loader = makeLoader()
        _ = await loader.load(def, ordinal: 1)
        let state = await loader.reload(def, ordinal: 1)
        guard case .ready = state else { return XCTFail("expected ready, got \(state)") }
        XCTAssertEqual(http.requested.filter { $0.path == "/1.json" }.count, 2)
        XCTAssertEqual(http.requested.filter { $0.path == "/1.png" }.count, 2)
    }

    func testUnknownOrdinalFailsWithoutRetry() async throws {
        let loader = makeLoader()
        let state = await loader.load(def, ordinal: 99)
        XCTAssertEqual(state, .failed(canRetry: false))
    }

    // MARK: Cancellation and offline

    func testPrepareCancelsOutOfWindowWorkWithoutFailureOrBroken() async throws {
        for n in 1...40 { serveStrip(n) }
        http.hold { $0.path.hasSuffix(".json") }
        let loader = makeLoader()
        await loader.prepare(def, around: 10)
        await waitUntil("first request") { !http.requested.isEmpty }
        await loader.prepare(def, around: 30)  // 11...20 are now outside 25...50
        http.release()
        await waitUntil("31...40") { detailRequests().isSuperset(of: Set(31...40)) }
        try await Task.sleep(for: .milliseconds(300))
        let broken = await loader.isBroken("num")
        XCTAssertFalse(broken)
        // A cancelled strip was never recorded as failed: loading it now succeeds and still extracts.
        let state = await loader.load(def, ordinal: 12)
        guard case .ready = state else { return XCTFail("expected ready, got \(state)") }
    }

    func testCancelledWorkDoesNotCountTowardBroken() async throws {
        for n in 1...3 { serveNoImage(n) }
        http.hold { $0.path.hasSuffix(".json") }
        let loader = makeLoader()
        await loader.prepare(def, around: 0)  // 1...10
        await waitUntil("requests") { !http.requested.isEmpty }
        await loader.prepare(def, around: 100)  // cancels all of it
        http.release()
        try await Task.sleep(for: .milliseconds(300))
        let broken = await loader.isBroken("num")
        XCTAssertFalse(broken)
        serveStrip(4); serveStrip(5)
        _ = await loader.load(def, ordinal: 1)  // one noImage; a stale run would not matter, but must not reach 3
        _ = await loader.load(def, ordinal: 2)
        let stillFine = await loader.isBroken("num")
        XCTAssertFalse(stillFine)
    }

    func testLoadJoiningCancelledJobRestartsAndIsReady() async throws {
        for n in 1...40 { serveStrip(n) }
        http.hold { $0.path == "/5.json" }
        let loader = makeLoader()
        await loader.prepare(def, around: 0)
        await waitUntil("5.json requested") { detailRequests().contains(5) }
        async let joined = loader.load(def, ordinal: 5)
        try await Task.sleep(for: .milliseconds(50))
        await loader.prepare(def, around: 30)  // cancels the job `load` joined
        http.release()
        let state = await joined
        guard case .ready(let strip) = state else { return XCTFail("expected ready, got \(state)") }
        XCTAssertEqual(strip.ordinal, 5)
    }

    func testTransportFailureSetsOfflineFlagAndSuccessClearsIt() async throws {
        serveStrip(1)
        http.failure = URLError(.notConnectedToInternet)
        let loader = makeLoader()
        let failed = await loader.load(def, ordinal: 1)
        XCTAssertEqual(failed, .failed(canRetry: true))
        var offline = await loader.lastTransportFailed
        XCTAssertTrue(offline)
        let broken = await loader.isBroken("num")
        XCTAssertFalse(broken)
        http.failure = nil
        let state = await loader.load(def, ordinal: 1)
        guard case .ready = state else { return XCTFail("expected ready, got \(state)") }
        offline = await loader.lastTransportFailed
        XCTAssertFalse(offline)
    }

    // MARK: Finished strips

    /// Counts committed transactions that changed the `strip` table until cancelled.
    private func countStripWrites() async throws -> (Locked<Int>, AnyDatabaseCancellable) {
        let writes = Locked(0)
        let observation = DatabaseRegionObservation(tracking: Table("strip"))
        let cancellable = observation.start(in: db.queue, onError: { _ in }, onChange: { _ in writes.mutate { $0 += 1 } })
        try await db.queue.write { _ in }  // the observer is in place once this write has run
        return (writes, cancellable)
    }

    private func sizesStored(_ range: ClosedRange<Int>) throws -> Bool {
        let stored = try db.queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM strip WHERE comicId = 'num' AND ordinal BETWEEN ? AND ? AND pixelWidth IS NOT NULL",
                             arguments: [range.lowerBound, range.upperBound])
        }
        return stored == range.count
    }

    /// Last-used stamps of the cached image files (the cache touches a file each time it serves it).
    private func modificationDates() -> [String: Date] {
        var dates: [String: Date] = [:]
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: Array(keys))
        while let url = walker?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let date = values.contentModificationDate else { continue }
            dates[url.lastPathComponent] = date
        }
        return dates
    }

    func testLoadingAFinishedStripAgainWritesNothing() async throws {
        serveStrip(1)
        let loader = makeLoader()
        _ = await loader.load(def, ordinal: 1)
        let (writes, observation) = try await countStripWrites()
        let again = await loader.load(def, ordinal: 1)
        guard case .ready = again else { return XCTFail("expected ready, got \(again)") }
        try await db.queue.write { _ in }
        XCTAssertEqual(writes.value, 0, "the stored size was already right")
        observation.cancel()
    }

    func testSecondPrepareSkipsFinishedStrips() async throws {
        for n in 1...40 { serveStrip(n) }
        let loader = makeLoader()
        await loader.prepare(def, around: 10)
        await waitUntil("11...20 finished") { (try? sizesStored(11...20)) == true }
        try await Task.sleep(for: .milliseconds(200))  // let the jobs record that they finished
        let dates = modificationDates()
        let requests = http.requested.count
        let (writes, observation) = try await countStripWrites()
        await loader.prepare(def, around: 10)
        await loader.prepare(def, around: 11)  // a page turn: only strip 21 is new
        await waitUntil("21 finished") { (try? sizesStored(21...21)) == true }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(writes.value, 2, "strip 21 only: its extracted details, then its size")
        XCTAssertEqual(http.requested.count, requests + 2, "21's details and image only")
        let after = modificationDates()
        for (name, date) in dates { XCTAssertEqual(after[name], date, "\(name) was touched again") }
        observation.cancel()
    }

    func testPrepareRedoesAFinishedStripWhoseImageWasEvicted() async throws {
        for n in 1...40 { serveStrip(n) }
        let loader = makeLoader()
        await loader.prepare(def, around: 10)
        await waitUntil("11...20 finished") { (try? sizesStored(11...20)) == true }
        try await Task.sleep(for: .milliseconds(200))
        let cache = ImageCache(http: http, directory: dir)
        let cached = await cache.cachedFile(for: URL(string: "https://img.test/15.png")!, comic: "num")
        let file = try XCTUnwrap(cached)
        try FileManager.default.removeItem(at: file)
        await loader.prepare(def, around: 10)
        await waitUntil("15.png fetched again") { http.requested.filter { $0.path == "/15.png" }.count == 2 }
    }

    func testReloadForgetsThatAStripFinished() async throws {
        for n in 1...40 { serveStrip(n) }
        let loader = makeLoader()
        await loader.prepare(def, around: 10)
        await waitUntil("11...20 finished") { (try? sizesStored(11...20)) == true }
        try await Task.sleep(for: .milliseconds(200))
        _ = await loader.reload(def, ordinal: 12)
        XCTAssertEqual(http.requested.filter { $0.path == "/12.json" }.count, 2)
        XCTAssertEqual(http.requested.filter { $0.path == "/12.png" }.count, 2)
    }
}

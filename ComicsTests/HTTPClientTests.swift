import XCTest
@testable import Comics

/// Records when each request started and finished, and answers after a short delay.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    struct Event { let url: URL; let start: Date; let end: Date; let userAgent: String? }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _events: [Event] = []
    nonisolated(unsafe) static var statusByPath: [String: Int] = [:]
    static let delay: TimeInterval = 0.1

    static var events: [Event] { lock.withLock { _events } }
    static func reset() { lock.withLock { _events = []; statusByPath = [:] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let start = Date()
        let url = request.url!
        let agent = request.value(forHTTPHeaderField: "User-Agent")
        let status = Self.lock.withLock { Self.statusByPath[url.path] } ?? 200
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [self] in
            Self.lock.withLock { Self._events.append(Event(url: url, start: start, end: Date(), userAgent: agent)) }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("ok".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class HTTPClientTests: XCTestCase {
    private func makeClient(gap: Duration = .milliseconds(250)) -> PoliteHTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        return PoliteHTTPClient(session: URLSession(configuration: config), gap: gap)
    }

    override func setUp() { RecordingURLProtocol.reset() }

    func testSameHostRequestsAreSerialisedWithAGap() async throws {
        let client = makeClient()
        let a = URL(string: "https://one.example/a")!
        let b = URL(string: "https://one.example/b")!
        async let ra = client.get(a)
        async let rb = client.get(b)
        _ = try await (ra, rb)

        let events = RecordingURLProtocol.events.sorted { $0.start < $1.start }
        XCTAssertEqual(events.count, 2)
        XCTAssertGreaterThanOrEqual(events[1].start.timeIntervalSince(events[0].start), 0.25)
        XCTAssertGreaterThanOrEqual(events[1].start, events[0].end, "same-host requests must not overlap")
    }

    func testDifferentHostsOverlap() async throws {
        let client = makeClient()
        async let ra = client.get(URL(string: "https://one.example/a")!)
        async let rb = client.get(URL(string: "https://two.example/b")!)
        _ = try await (ra, rb)

        let events = RecordingURLProtocol.events.sorted { $0.start < $1.start }
        XCTAssertEqual(events.count, 2)
        XCTAssertLessThan(events[1].start, events[0].end, "different hosts should run concurrently")
    }

    func testNon2xxThrowsStatusError() async {
        RecordingURLProtocol.statusByPath["/missing"] = 404
        let client = makeClient()
        do {
            _ = try await client.get(URL(string: "https://one.example/missing")!)
            XCTFail("expected an error")
        } catch let error as HTTPError {
            XCTAssertEqual(error, .status(404))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSendsGenericUserAgent() async throws {
        let client = makeClient()
        _ = try await client.get(URL(string: "https://one.example/a")!)
        XCTAssertEqual(RecordingURLProtocol.events.first?.userAgent, HTTPClientIdentity.userAgent)
        XCTAssertEqual(HTTPClientIdentity.userAgent, "Comics/1.0")
    }

    func testFailedRequestStillReleasesTheHost() async throws {
        RecordingURLProtocol.statusByPath["/bad"] = 500
        let client = makeClient(gap: .milliseconds(10))
        _ = try? await client.get(URL(string: "https://one.example/bad")!)
        let (data, _) = try await client.get(URL(string: "https://one.example/good")!)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
    }
}

final class StubHTTPTests: XCTestCase {
    func testServesRoutesRecordsRequestsAndRejectsUnrouted() async throws {
        let stub = StubHTTP(routes: [
            "https://xkcd.com/1/info.0.json": (200, [:], StubHTTP.fixture("xkcd-1.json"))
        ])
        let (data, response) = try await stub.get(URL(string: "https://xkcd.com/1/info.0.json")!)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(data.isEmpty)
        do {
            _ = try await stub.get(URL(string: "https://xkcd.com/2/info.0.json")!)
            XCTFail("expected 404")
        } catch let error as HTTPError {
            XCTAssertEqual(error, .status(404))
        }
        XCTAssertEqual(stub.requested.count, 2)
    }

    func testFixturesLookLikeTheRealPages() throws {
        func text(_ name: String) -> String { String(decoding: StubHTTP.fixture(name), as: UTF8.self) }
        XCTAssertEqual(text("qc-100.html").components(separatedBy: "id=\"strip\"").count - 1, 1)
        XCTAssertGreaterThan(text("smbc-archive.html").components(separatedBy: "<option").count - 1, 7000)
        XCTAssertEqual(StubHTTP.fixture("smbc-strip.webp").prefix(4), Data("RIFF".utf8))
        XCTAssertGreaterThan(Int(text("doa-total.txt").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, 1000)
    }
}

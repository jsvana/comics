import Foundation
@testable import Comics

/// Offline HTTPFetching double. Routes are keyed by absolute URL string; an unrouted URL is a 404.
final class StubHTTP: HTTPFetching, @unchecked Sendable {
    typealias Route = (status: Int, headers: [String: String], body: Data)

    private let lock = NSLock()
    private var _routes: [String: Route]
    private var _requested: [URL] = []
    private var _gate: ((URL) -> Bool)?
    private var _gated: [CheckedContinuation<Void, Never>] = []
    private var _failure: Error?

    init(routes: [String: Route] = [:]) { _routes = routes }

    var routes: [String: Route] {
        get { lock.withLock { _routes } }
        set { lock.withLock { _routes = newValue } }
    }

    var requested: [URL] { lock.withLock { _requested } }

    /// While set, a request for which `gate` returns true is recorded and then suspends until `release()`.
    func hold(where gate: @escaping (URL) -> Bool) { lock.withLock { _gate = gate } }

    /// Resumes every suspended request and stops gating.
    func release() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            _gate = nil
            defer { _gated = [] }
            return _gated
        }
        waiting.forEach { $0.resume() }
    }

    /// Makes every request throw `error` (a transport failure) until set back to nil.
    var failure: Error? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let held: Bool = lock.withLock {
            _requested.append(url)
            return _gate?(url) ?? false
        }
        if held {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = lock.withLock {
                    if _gate == nil { return true }  // released in the meantime
                    _gated.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        if let failure = lock.withLock({ _failure }) { throw failure }
        let route: Route? = lock.withLock { _routes[url.absoluteString] }
        guard let route else { throw HTTPError.status(404) }
        guard (200..<300).contains(route.status) else { throw HTTPError.status(route.status) }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: route.headers)!
        return (route.body, response)
    }

    /// Loads a saved site page from the test bundle's Fixtures folder.
    static func fixture(_ name: String) -> Data {
        let bundle = Bundle(for: StubHTTP.self)
        guard let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing fixture \(name)")
        }
        return data
    }
}

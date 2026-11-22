import Foundation
@testable import Comics

/// Offline HTTPFetching double. Routes are keyed by absolute URL string; an unrouted URL is a 404.
final class StubHTTP: HTTPFetching, @unchecked Sendable {
    typealias Route = (status: Int, headers: [String: String], body: Data)

    private let lock = NSLock()
    private var _routes: [String: Route]
    private var _requested: [URL] = []

    init(routes: [String: Route] = [:]) { _routes = routes }

    var routes: [String: Route] {
        get { lock.withLock { _routes } }
        set { lock.withLock { _routes = newValue } }
    }

    var requested: [URL] { lock.withLock { _requested } }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let route: Route? = lock.withLock {
            _requested.append(url)
            return _routes[url.absoluteString]
        }
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

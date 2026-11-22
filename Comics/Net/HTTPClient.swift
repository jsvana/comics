import Foundation

protocol HTTPFetching: Sendable {
    func get(_ url: URL) async throws -> (Data, HTTPURLResponse)
}

enum HTTPError: Error, Equatable {
    case status(Int)
    case notHTTP
}

enum HTTPClientIdentity {
    static let userAgent = "Comics/1.0"
}

/// Fetches pages one at a time per host, leaving a gap between consecutive requests to the same host.
actor PoliteHTTPClient: HTTPFetching {
    private struct HostState {
        var busy = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var lastFinished: ContinuousClock.Instant?
    }

    private let session: URLSession
    private let gap: Duration
    private let clock = ContinuousClock()
    private var hosts: [String: HostState] = [:]

    init(session: URLSession = .shared, gap: Duration = .milliseconds(250)) {
        self.session = session
        self.gap = gap
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let host = url.host?.lowercased() ?? ""
        await acquire(host)
        do {
            if let last = hosts[host]?.lastFinished {
                try await clock.sleep(until: last.advanced(by: gap))
            }
            let result = try await perform(url)
            release(host)
            return result
        } catch {
            release(host)
            throw error
        }
    }

    private func perform(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(HTTPClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError.status(http.statusCode) }
        return (data, http)
    }

    private func acquire(_ host: String) async {
        var state = hosts[host] ?? HostState()
        if state.busy {
            await withCheckedContinuation { continuation in
                state.waiters.append(continuation)
                hosts[host] = state
            }
        } else {
            state.busy = true
            hosts[host] = state
        }
    }

    private func release(_ host: String) {
        var state = hosts[host] ?? HostState()
        state.lastFinished = clock.now
        if state.waiters.isEmpty {
            state.busy = false
            hosts[host] = state
        } else {
            let next = state.waiters.removeFirst()
            hosts[host] = state
            next.resume()
        }
    }
}

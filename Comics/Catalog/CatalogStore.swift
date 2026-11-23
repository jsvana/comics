import Foundation
import Observation

/// The catalog the app offers: the bundled copy, replaced by the remote copy when a newer one
/// downloads and parses. A remote copy that fails to download, does not decode, has another schema
/// or a lower version is ignored silently (the remote file may not exist yet; that is not an error).
///
/// Thread safety: `catalog` changes only on the main actor; everything else is behind `lock`.
/// File reads happen in `init` (two small files), downloads and file writes in `refreshIfDue`.
@Observable
final class CatalogStore: @unchecked Sendable {
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    static let defaultRemote = URL(string: "https://raw.githubusercontent.com/jsvana/comics/main/catalog/catalog.json")!
    /// `UserDefaults` key for a remote URL chosen in Settings.
    static let remoteDefaultsKey = "catalogURL"

    /// A catalog address typed in Settings: an `https` URL with a host, else nil.
    static func parseRemote(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    enum RefreshOutcome: Equatable {
        /// Checked less than 24 hours ago; no request made.
        case notDue
        case adopted
        /// Downloaded, but not usable: does not decode, another schema, or a lower version.
        case rejected
        /// The download failed (offline, 404, ...).
        case failed
    }

    private(set) var catalog: Catalog

    /// Called after a remote catalog is adopted, before `refreshIfDue` returns. Set once before use.
    @ObservationIgnored var onAdopt: (@Sendable (Catalog) async -> Void)?

    @ObservationIgnored private let http: HTTPFetching
    @ObservationIgnored private let storage: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var _remote: URL
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var refreshing = false

    /// `storage` is a folder for the adopted copy and the time of the last check. The bundled
    /// catalog is part of the app, so failing to decode it is a programming error.
    init(bundled: Data, http: HTTPFetching, storage: URL, remote: URL, now: @escaping () -> Date = Date.init) {
        self.http = http
        self.storage = storage
        self.now = now
        _remote = remote
        let shipped: Catalog
        do {
            shipped = try JSONDecoder().decode(Catalog.self, from: bundled)
        } catch {
            fatalError("bundled catalog does not decode: \(error)")
        }
        // An app update may bundle a newer catalog than the copy adopted earlier.
        if let data = try? Data(contentsOf: storage.appendingPathComponent(Self.savedName)),
           let saved = Self.usable(data), saved.version >= shipped.version {
            catalog = saved
        } else {
            catalog = shipped
        }
        if let text = try? String(contentsOf: storage.appendingPathComponent(Self.checkedName), encoding: .utf8),
           let seconds = Double(text) {
            lastCheck = Date(timeIntervalSince1970: seconds)
        }
    }

    /// Where the remote catalog is read from.
    var remote: URL {
        get { lock.withLock { _remote } }
        set { lock.withLock { _remote = newValue } }
    }

    /// Downloads the remote catalog unless it was checked in the last 24 hours (`force` ignores
    /// that; only a completed HTTP exchange counts as a check, not a transport failure), and adopts it if it decodes, has the supported schema and a version not lower than
    /// the current one. Concurrent calls collapse into the one already running.
    @discardableResult
    func refreshIfDue(force: Bool) async -> RefreshOutcome {
        let url: URL? = lock.withLock {
            if refreshing { return nil }
            if !force, let last = lastCheck, now().timeIntervalSince(last) < Self.refreshInterval { return nil }
            refreshing = true
            return _remote
        }
        guard let url else { return .notDue }
        defer { lock.withLock { refreshing = false } }

        let data: Data
        do {
            (data, _) = try await http.get(url)
        } catch HTTPError.status {
            recordCheck()  // the server answered (a 404 while the remote file does not exist, say)
            return .failed
        } catch {
            return .failed  // offline or cancelled: try again at the next activation, not in 24 hours
        }
        recordCheck()
        guard let downloaded = Self.usable(data) else { return .rejected }
        let adopted = await MainActor.run { () -> Bool in
            guard downloaded.version >= catalog.version else { return false }
            if downloaded != catalog { catalog = downloaded }
            return true
        }
        guard adopted else { return .rejected }
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try? data.write(to: storage.appendingPathComponent(Self.savedName), options: .atomic)
        await onAdopt?(downloaded)
        return .adopted
    }

    // MARK: Internals

    private static let savedName = "catalog-remote.json"
    private static let checkedName = "catalog-checked.txt"

    private static func usable(_ data: Data) -> Catalog? {
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              catalog.schema == Catalog.supportedSchema else { return nil }
        return catalog
    }

    private func recordCheck() {
        let stamp = now()
        lock.withLock { lastCheck = stamp }
        try? FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try? String(stamp.timeIntervalSince1970).write(to: storage.appendingPathComponent(Self.checkedName), atomically: true, encoding: .utf8)
    }
}

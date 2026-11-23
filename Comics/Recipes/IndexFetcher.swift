import Foundation

struct IndexEntry: Equatable, Codable {
    let key: String
    var title: String?
    var date: String?
    var page: URL?
}

enum IndexError: Error, Equatable {
    case noMatch
    case lastKeyMissing
}

/// Turns an index recipe into the strips not yet known, oldest first.
struct IndexFetcher {
    let http: HTTPFetching

    init(http: HTTPFetching) { self.http = http }

    func newEntries(
        _ recipe: IndexRecipe, knownCount: Int, lastKey: String?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [IndexEntry] {
        switch recipe {
        case .numbered(let r): return try await numbered(r, knownCount: knownCount, lastKey: lastKey, progress: progress)
        case .wordpress(let r): return try await wordpress(r, knownCount: knownCount, progress: progress)
        case .linkList(let r): return try await linkList(r, knownCount: knownCount, lastKey: lastKey, progress: progress)
        }
    }

    private func text(_ url: URL) async throws -> String {
        let (data, _) = try await http.get(url)
        return String(decoding: data, as: UTF8.self)
    }

    private func numbered(
        _ r: IndexRecipe.Numbered, knownCount: Int, lastKey: String?, progress: (@Sendable (Double) -> Void)?
    ) async throws -> [IndexEntry] {
        let body = try await text(r.latestURL)
        guard let n = Pattern.first(r.latestPattern, in: body, group: "n").flatMap({ Int($0) }) else {
            throw IndexError.noMatch
        }
        let skip = Set(r.skip)
        var keys = (r.first...max(r.first, n)).filter { !skip.contains($0) }
        if n < r.first { keys = [] }
        if let last = lastKey.flatMap({ Int($0) }) {
            keys = keys.filter { $0 > last }
        } else {
            keys = Array(keys.dropFirst(knownCount))
        }
        progress?(1)
        return keys.map { IndexEntry(key: String($0)) }
    }

    private struct WPItem: Decodable {
        struct Rendered: Decodable { let rendered: String }
        let slug: String
        let date: String?
        let link: URL?
        let title: Rendered?
    }

    private static let wordpressPageSize = 100

    private func wordpress(
        _ r: IndexRecipe.WordPress, knownCount: Int, progress: (@Sendable (Double) -> Void)?
    ) async throws -> [IndexEntry] {
        var out: [IndexEntry] = []
        var offset = knownCount
        while true {
            let url = URL(string: r.api.absoluteString
                + "?per_page=\(Self.wordpressPageSize)&order=asc&orderby=date&_fields=id,slug,date,title,link&offset=\(offset)")!
            let (data, response) = try await http.get(url)
            let items = try JSONDecoder().decode([WPItem].self, from: data)
            out += items.map {
                IndexEntry(key: $0.slug, title: $0.title.map { Pattern.decodeEntities($0.rendered) }, date: $0.date, page: $0.link)
            }
            offset += items.count
            if let total = response.value(forHTTPHeaderField: "X-WP-Total").flatMap({ Int($0) }), total > knownCount {
                progress?(min(1, Double(offset - knownCount) / Double(total - knownCount)))
            }
            if items.count < Self.wordpressPageSize { break }
        }
        progress?(1)
        return out
    }

    private func linkList(
        _ r: IndexRecipe.LinkList, knownCount: Int, lastKey: String?, progress: (@Sendable (Double) -> Void)?
    ) async throws -> [IndexEntry] {
        let body = try await text(r.url)
        let matches = Pattern.all(r.itemPattern, in: body)
        func entry(_ m: [String: String]) -> IndexEntry? {
            guard let key = m["key"] else { return nil }
            return IndexEntry(
                key: key,
                title: m["title"].map { Pattern.decodeEntities($0) },
                date: m["date"],
                page: URL(string: r.pageTemplate.replacingOccurrences(of: "{key}", with: key)))
        }
        // A list that is not in reading order can capture a number per item as `order` (a post
        // number, say). Items are then read in ascending `order`, and a repeated key keeps its
        // highest one.
        let numbered = matches.compactMap { m -> (Int, IndexEntry)? in
            guard let order = m["order"].flatMap({ Int($0) }), let item = entry(m) else { return nil }
            return (order, item)
        }
        if !numbered.isEmpty {
            var seen = Set<String>()
            let newestFirst = numbered.sorted { $0.0 > $1.0 }.map(\.1).filter { seen.insert($0.key).inserted }
            return try tail(Array(newestFirst.reversed()), knownCount: knownCount, lastKey: lastKey, progress: progress)
        }
        var items = matches.compactMap(entry)
        guard !items.isEmpty else { throw IndexError.noMatch }
        // Oldest first, then keep each key's first occurrence. Pages that open with featured
        // teasers for recent strips repeat those keys near the newest end; the occurrence nearest
        // the oldest end is the one in the full list.
        if r.newestFirst { items.reverse() }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.key).inserted }
        return try tail(items, knownCount: knownCount, lastKey: lastKey, progress: progress)
    }

    /// The entries after what is already known.
    private func tail(_ items: [IndexEntry], knownCount: Int, lastKey: String?,
                      progress: (@Sendable (Double) -> Void)?) throws -> [IndexEntry] {
        progress?(1)
        if let lastKey {
            guard let i = items.firstIndex(where: { $0.key == lastKey }) else { throw IndexError.lastKeyMissing }
            return Array(items[(i + 1)...])
        }
        return Array(items.dropFirst(knownCount))
    }
}

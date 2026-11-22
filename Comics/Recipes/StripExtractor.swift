import Foundation

struct StripDetails: Equatable, Codable {
    let image: URL
    var title: String?
    var hover: String?
    var bonus: URL?
    let page: URL
}

enum StripError: Error, Equatable {
    /// The page loaded but the recipe found nothing. Counts toward "recipe broken".
    case noImage
    /// The server answered with a non-2xx status. Not evidence of a broken recipe.
    case http(Int)
}

/// Turns one index entry into a strip's image URL, title, hover text and bonus image.
struct StripExtractor {
    let http: HTTPFetching

    init(http: HTTPFetching) { self.http = http }

    func details(_ recipe: StripRecipe, entry: IndexEntry) async throws -> StripDetails {
        switch recipe {
        case .json(let r): return try await json(r, entry: entry)
        case .html(let r): return try await html(r, entry: entry)
        }
    }

    private func substitute(_ template: String, entry: IndexEntry) -> String {
        template
            .replacingOccurrences(of: "{key}", with: entry.key)
            .replacingOccurrences(of: "{page}", with: entry.page?.absoluteString ?? "")
    }

    private func get(_ url: URL) async throws -> Data {
        do {
            return try await http.get(url).0
        } catch HTTPError.status(let code) {
            throw StripError.http(code)
        }
    }

    /// Resolves against the page, upgrades http to https and escapes characters a URL can't hold.
    private func imageURL(_ ref: String, page: URL) -> URL? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var url = Pattern.resolve(trimmed, against: page) else { return nil }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        if parts.scheme == "http" { parts.scheme = "https" }
        guard parts.host != nil else { return nil }
        url = parts.url ?? url
        return url
    }

    private func json(_ r: StripRecipe.JSONStrip, entry: IndexEntry) async throws -> StripDetails {
        guard let pageURL = URL(string: substitute(r.page, entry: entry)),
              let dataURL = URL(string: substitute(r.url, entry: entry)) else { throw StripError.noImage }
        let data = try await get(dataURL)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ref = object[r.image] as? String,
              let image = imageURL(ref, page: pageURL) else { throw StripError.noImage }
        func text(_ key: String?) -> String? {
            guard let key, let s = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        return StripDetails(image: image, title: text(r.title), hover: text(r.hover), bonus: nil, page: pageURL)
    }

    private func html(_ r: StripRecipe.HTMLStrip, entry: IndexEntry) async throws -> StripDetails {
        guard let fetchURL = URL(string: substitute(r.url, entry: entry)), fetchURL.host != nil else { throw StripError.noImage }
        let body = String(decoding: try await get(fetchURL), as: UTF8.self)
        let page = entry.page ?? fetchURL
        func capture(_ pattern: String?) -> String? {
            guard let pattern, let raw = Pattern.first(pattern, in: body, group: "v") else { return nil }
            let s = Pattern.decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        guard let ref = capture(r.imagePattern), let image = imageURL(ref, page: page) else { throw StripError.noImage }
        return StripDetails(
            image: image,
            title: capture(r.titlePattern),
            hover: capture(r.hoverPattern),
            bonus: capture(r.bonusPattern).flatMap { imageURL($0, page: page) },
            page: page)
    }
}

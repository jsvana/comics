import CoreGraphics
import Foundation
import Observation

/// What the library, "Add comics" and settings screens show, computed off the main thread and
/// cached here so view bodies never touch the database. Also runs adds, which outlive the sheet
/// that started them (closing the sheet does not cancel an add; Cancel does).
@Observable @MainActor
final class LibraryModel {
    /// A strip image for a card, and the image URL it was made from (a moved bookmark changes it).
    struct Thumbnail {
        let source: URL
        let image: CGImage
    }

    struct AddState: Equatable {
        /// 0...1, or nil while the index source gives no progress.
        var progress: Double?
        var cancelling = false
    }

    static let thumbnailPixels = 240

    /// Library comics (not removed): those with new strips first, then the most recently read.
    private(set) var cards: [ComicSummary] = []
    /// Every comic with a row, removed ones included, by id.
    private(set) var rows: [String: ComicSummary] = [:]
    private(set) var loaded = false
    private(set) var thumbnails: [String: Thumbnail] = [:]
    private(set) var adding: [String: AddState] = [:]
    /// The last add failure per comic, as a sentence.
    private(set) var addErrors: [String: String] = [:]

    @ObservationIgnored let env: AppEnvironment
    @ObservationIgnored private var addTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var askedCatalogAboutBroken = false

    init(env: AppEnvironment) { self.env = env }

    // MARK: Loading

    /// Re-reads every card from the database (off the main thread).
    func reload() async {
        let library = env.library
        let all = await Task.detached { library.summaries() }.value
        rows = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        cards = Self.sorted(all.filter { !$0.removed && $0.def != nil })
        loaded = true
        thumbnails = thumbnails.filter { id, thumb in rows[id]?.image == thumb.source }
        if cards.contains(where: \.broken), !askedCatalogAboutBroken {
            // The catalog may already carry a fixed recipe; check now rather than tomorrow.
            askedCatalogAboutBroken = true
            let env = env
            Task { await env.refreshCatalog(force: true) }
        }
    }

    static func sorted(_ cards: [ComicSummary]) -> [ComicSummary] {
        cards.sorted { a, b in
            let aNew = { if case .new = a.status { return true } else { return false } }()
            let bNew = { if case .new = b.status { return true } else { return false } }()
            if aNew != bNew { return aNew }
            let aRead = a.lastReadAt ?? a.addedAt
            let bRead = b.lastReadAt ?? b.addedAt
            if aRead != bRead { return aRead > bRead }
            return a.id < b.id
        }
    }

    /// Makes a thumbnail for each card whose bookmarked strip has none yet, from the image cache
    /// only: showing the library never fetches a page or an image. A card with no cached image
    /// keeps its placeholder. Runs in the caller's task, so leaving the library cancels it.
    func loadThumbnails() async {
        for card in cards {
            guard !Task.isCancelled else { return }
            guard let source = card.image, thumbnails[card.id]?.source != source else { continue }
            guard let file = await env.images.cachedFile(for: source, comic: card.id), !Task.isCancelled else { continue }
            let pixels = Self.thumbnailPixels
            let image = await Task.detached(priority: .utility) {
                ImageCache.downsampled(file, maxPixel: pixels)
            }.value
            if let image { thumbnails[card.id] = Thumbnail(source: source, image: image) }
        }
    }

    // MARK: Changes

    /// Starts indexing `def` and adds it to the library when the index is built. The comic appears
    /// in `cards` only then; cancelling or failing stores nothing.
    func add(_ def: ComicDef, start: StartPoint) {
        guard addTasks[def.id] == nil, adding[def.id] == nil else { return }
        let id = def.id
        adding[id] = AddState()
        addErrors[id] = nil
        let library = env.library
        addTasks[id] = Task { [weak self] in
            var failure: Error?
            do {
                try await library.add(def, start: start) { fraction in
                    Task { @MainActor in self?.progressed(id, fraction) }
                }
            } catch {
                failure = error
            }
            await self?.finishAdd(id, failure: failure)
        }
    }

    func cancelAdd(_ id: String) {
        guard let task = addTasks[id] else { return }
        adding[id]?.cancelling = true
        task.cancel()
    }

    /// Hides the comic (its bookmark is kept for 30 days).
    func remove(_ id: String) async {
        let library = env.library
        await Task.detached { library.remove(id) }.value
        await reload()
    }

    private func progressed(_ id: String, _ fraction: Double) {
        guard addTasks[id] != nil, adding[id] != nil else { return }
        adding[id]?.progress = min(max(fraction, 0), 1)
    }

    private func finishAdd(_ id: String, failure: Error?) async {
        let cancelled = adding[id]?.cancelling ?? false
        addTasks[id] = nil
        if let failure, !cancelled, !(failure is CancellationError) {
            addErrors[id] = Self.describe(failure)
        }
        // Clear the progress row only once the new card is in `rows`, so the row never flips back to "Add".
        await reload()
        adding[id] = nil
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case IndexError.noMatch, IndexError.lastKeyMissing:
            return "Couldn't read this comic's archive. Its recipe may need an update."
        case HTTPError.status(let code):
            return "The site answered with an error (\(code))."
        case let url as URLError where url.code == .notConnectedToInternet || url.code == .networkConnectionLost:
            return "You're offline."
        default:
            return "Couldn't reach the site."
        }
    }
}

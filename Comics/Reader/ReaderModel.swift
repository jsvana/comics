import CoreGraphics
import Foundation
import Observation

/// The reader's state machine: which strips are on screen, how they are arranged, and every move
/// of the bookmark. The bookmark is the first strip of the spread; it is written through
/// `PlaceKeeper` on every move, and nothing here moves it except the reader's own actions.
@Observable @MainActor
final class ReaderModel {
    /// Strips kept loaded around the bookmark: two behind (to size the previous spread) and three
    /// ahead (the current spread plus the next one), so a move rarely waits on a layout change.
    private static let loadBehind = 2
    private static let loadAhead = 3
    /// States further than this from the bookmark are dropped.
    private static let keep = 6
    private static let warningSeconds: Double = 4

    let def: ComicDef

    var form: WindowForm = .narrow {
        didSet { if form != oldValue { relayout() } }
    }
    var canvas: CGSize = .zero {
        didSet { if canvas != oldValue { relayout() } }
    }

    /// The bookmark: the first strip of the spread on screen.
    private(set) var first: Int
    private(set) var strips: [Int: StripState] = [:]
    /// Index entries (key, title, date) for the strips in `strips`, for captions.
    private(set) var entries: [Int: IndexEntry] = [:]
    private(set) var layout: SpreadLayout = .single
    /// Where "Back to #N" goes; set by a jump, cleared by `next()` and `goBack()`.
    private(set) var backTarget: Int?
    /// Number of strips in the comic's index.
    private(set) var count: Int
    /// Jump history, newest first.
    private(set) var history: [JumpEntry] = []
    /// True for a few seconds after a bookmark write failed.
    private(set) var saveFailed = false

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let places: PlaceKeeper
    @ObservationIgnored private let loader: StripLoader
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var warningTask: Task<Void, Never>?

    init(def: ComicDef, library: LibraryStore, places: PlaceKeeper, loader: StripLoader) {
        self.def = def
        self.library = library
        self.places = places
        self.loader = loader
        count = library.count(def.id)
        first = places.bookmark(def.id)
        history = places.history(def.id)
        places.onError = { [weak self] _ in
            Task { @MainActor in self?.showSaveWarning() }
        }
        moved()
    }

    /// The strips on screen, in order.
    var spread: [Int] {
        layout == .single ? [first] : [first, first + 1]
    }

    /// The comic's last strip is on screen.
    var atEnd: Bool {
        (spread.last ?? first) >= count
    }

    // MARK: Moves

    /// Advances by the spread on screen. At the end this does nothing.
    func next() {
        let target = first + SpreadPlanner.count(layout)
        guard target <= count else { return }
        places.step(def.id, to: target)
        first = target
        backTarget = nil
        moved()
    }

    /// Goes back by the size the previous spread would have, so `next()` then `previous()`
    /// returns to the same strip. If the strips before are not loaded yet, steps back one.
    func previous() {
        guard first > 1 else { return }
        var target = first - 1
        if first - 2 >= 1,
           SpreadPlanner.count(SpreadPlanner.layout(current: size(first - 2), next: size(first - 1), canvas: canvas, form: form)) == 2 {
            target = first - 2
        }
        places.step(def.id, to: target)
        first = target
        moved()
    }

    /// Scrubber, "go to", first, latest: remembers where the reader was, then moves.
    func go(to ordinal: Int) {
        guard count > 0 else { return }
        let target = min(max(ordinal, 1), count)
        guard target != first else { return }
        let old = first
        places.jump(def.id, to: target)
        first = target
        backTarget = old
        moved()
    }

    /// Returns to the newest place in the jump history.
    func goBack() {
        if let ordinal = places.back(def.id) {
            first = ordinal
        }
        backTarget = nil
        moved()
    }

    /// Forgets the strip's stored details and cached image and loads it again.
    func retry(_ ordinal: Int) {
        tasks[ordinal]?.cancel()
        strips[ordinal] = .loading
        let def = def
        let loader = loader
        tasks[ordinal] = Task { [weak self] in
            let state = await loader.reload(def, ordinal: ordinal)
            guard !Task.isCancelled else { return }
            self?.finished(ordinal, state)
        }
    }

    /// The view found a ready strip's cached image file gone (the cache evicted it): load it again.
    func imageMissing(_ ordinal: Int) {
        guard tasks[ordinal] == nil else { return }
        retry(ordinal)
    }

    /// The strip's page on the comic's own site: from its details once loaded, else from the index
    /// entry or the recipe's page template (so a strip that failed to load can still be opened).
    func originalPage(_ ordinal: Int) -> URL? {
        if case .ready(let strip) = strips[ordinal] { return strip.details.page }
        guard let entry = entries[ordinal] else { return nil }
        if let page = entry.page { return page }
        let template: String
        switch def.strip {
        case .json(let r): template = r.page
        case .html(let r): template = r.url
        }
        return URL(string: template.replacingOccurrences(of: "{key}", with: entry.key))
    }

    // MARK: Internals

    private func moved() {
        relayout()
        refreshWindow()
        history = places.history(def.id)
        let def = def
        let loader = loader
        let around = first
        Task { await loader.prepare(def, around: around) }
    }

    private func size(_ ordinal: Int) -> CGSize? {
        if case .ready(let strip) = strips[ordinal] { return strip.pixelSize }
        return nil
    }

    /// Recomputes the arrangement for the current `first`; never changes `first`.
    private func relayout() {
        let next = first < count ? size(first + 1) : nil
        let new = SpreadPlanner.layout(current: size(first), next: next, canvas: canvas, form: form)
        if new != layout { layout = new }
    }

    /// Starts loads for the strips around the bookmark and drops state far from it.
    private func refreshWindow() {
        let keep = (first - Self.keep)...(first + Self.keep)
        for (n, task) in tasks where !keep.contains(n) {
            task.cancel()
            tasks[n] = nil
        }
        for n in strips.keys where !keep.contains(n) { strips[n] = nil }
        for n in entries.keys where !keep.contains(n) { entries[n] = nil }

        guard count > 0 else { return }
        let low = max(1, first - Self.loadBehind)
        let high = min(count, first + Self.loadAhead)
        guard low <= high else { return }
        // The bookmarked strip first, then outwards.
        let order = [first] + (low...high).filter { $0 != first }.sorted { abs($0 - first) < abs($1 - first) }
        for n in order where (1...count).contains(n) { ensureLoaded(n) }
    }

    private func ensureLoaded(_ ordinal: Int) {
        guard tasks[ordinal] == nil else { return }
        switch strips[ordinal] {
        case .ready, .failed: return
        case .loading, nil: break
        }
        strips[ordinal] = .loading
        let def = def
        let loader = loader
        let library = library
        tasks[ordinal] = Task { [weak self] in
            async let entry = Task.detached { library.entry(def.id, ordinal: ordinal) }.value
            let state = await loader.load(def, ordinal: ordinal)
            let found = await entry
            // `.loading` back from the loader means our own work was cancelled: ask again next time.
            guard !Task.isCancelled, state != .loading else { return }
            if let found { self?.entries[ordinal] = found }
            self?.finished(ordinal, state)
        }
    }

    private func finished(_ ordinal: Int, _ state: StripState) {
        tasks[ordinal] = nil
        strips[ordinal] = state
        if ordinal == first || ordinal == first + 1 { relayout() }
    }

    private func showSaveWarning() {
        saveFailed = true
        warningTask?.cancel()
        warningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.warningSeconds))
            guard !Task.isCancelled else { return }
            self?.saveFailed = false
        }
    }
}

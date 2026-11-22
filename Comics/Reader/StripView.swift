import SwiftUI

/// How a strip's image is sized inside the space it is given. Pure; sizes in points.
enum StripSizing {
    enum Mode {
        /// Narrow window, one strip: the full width, scrolling if taller than the screen. A strip
        /// that overflows the box by only a little is shrunk to fit, so it reads without a scroll.
        case fitWidth
        /// One cell of a spread: as large as fits inside the box.
        case fitBox
        /// Wide window, one strip: fits the box, except a tall strip (more than twice as tall as
        /// wide), which would be unreadably narrow fitted; that is drawn at a readable width and scrolls.
        case wideSingle
    }

    /// Overflow (as a fraction of the box height) that `fitWidth` still shrinks away.
    static let shrinkSlack: CGFloat = 0.25
    /// Height over width beyond which a strip counts as tall.
    static let tallRatio: CGFloat = 2
    /// Width for a tall strip in a wide window.
    static let tallStripWidth: CGFloat = 560

    static func size(_ pixels: CGSize, box: CGSize, mode: Mode) -> CGSize {
        guard pixels.width > 0, pixels.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let ratio = pixels.height / pixels.width
        let fitted: CGSize = {
            let scale = min(box.width / pixels.width, box.height / pixels.height)
            return CGSize(width: pixels.width * scale, height: pixels.height * scale)
        }()
        switch mode {
        case .fitBox:
            return fitted
        case .fitWidth:
            let height = box.width * ratio
            if height > box.height && height <= box.height * (1 + shrinkSlack) { return fitted }
            return CGSize(width: box.width, height: height)
        case .wideSingle:
            if ratio <= tallRatio { return fitted }
            let width = min(box.width, tallStripWidth)
            return CGSize(width: width, height: width * ratio)
        }
    }
}

/// One strip: the image, a caption line (title · number or date), the hover text, and the bonus
/// image; or a spinner while it loads; or a "couldn't load" card that can be retried.
struct StripView: View {
    let ordinal: Int
    let state: StripState?
    let entry: IndexEntry?
    let box: CGSize
    let mode: StripSizing.Mode
    /// Horizontal inset for the caption, so text does not touch the screen edge under a full-width strip.
    let captionInset: CGFloat
    let originalPage: URL?
    let onRetry: () -> Void
    let onImageMissing: () -> Void

    @AppStorage("hoverTapToReveal") private var hoverTapToReveal = false
    @State private var hoverRevealed = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch state {
        case .ready(let strip):
            ready(strip)
        case .failed(let canRetry):
            failed(canRetry: canRetry)
        case .loading, nil:
            placeholder
        }
    }

    private func ready(_ strip: LoadedStrip) -> some View {
        let size = StripSizing.size(strip.pixelSize, box: box, mode: mode)
        return VStack(alignment: .leading, spacing: 6) {
            DecodedImage(file: strip.image, label: strip.details.title ?? "Strip \(ordinal)", onMissing: onImageMissing)
                .frame(width: size.width, height: size.height)
            VStack(alignment: .leading, spacing: 4) {
                Text(caption(strip))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let hover = strip.details.hover {
                    if hoverTapToReveal && !hoverRevealed {
                        Button("Tap to show") { hoverRevealed = true }
                            .font(.footnote)
                    } else {
                        Text(hover)
                            .font(.footnote)
                            .foregroundStyle(.primary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, captionInset)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: CaptionHeightKey.self, value: proxy.size.height)
            })
            if let bonus = strip.bonus {
                BonusImage(file: bonus, width: size.width)
                    .padding(.top, 6)
            }
        }
        .frame(width: size.width, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("strip-\(ordinal)")
    }

    /// `title · number-or-date`: the date when the index has one, else the site's number, else the ordinal.
    private func caption(_ strip: LoadedStrip) -> String {
        let number: String
        if let date = entry?.date {
            number = Self.formatDate(date)
        } else if let key = entry?.key, !key.isEmpty, key.allSatisfy(\.isNumber) {
            number = "#\(key)"
        } else {
            number = "#\(ordinal)"
        }
        guard let title = strip.details.title ?? entry?.title, !title.isEmpty else { return number }
        return "\(title) · \(number)"
    }

    /// `2012-05-03…` becomes "3 May 2012"; anything else is shown as given.
    static func formatDate(_ raw: String) -> String {
        let day = String(raw.prefix(10))
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return raw }
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC")!
        return date.formatted(style)
    }

    private var placeholderSize: CGSize {
        CGSize(width: box.width, height: min(box.height, box.width * 1.3))
    }

    private var placeholder: some View {
        ProgressView()
            .frame(width: placeholderSize.width, height: placeholderSize.height)
            .accessibilityIdentifier("strip-loading-\(ordinal)")
    }

    private func failed(canRetry: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Couldn't load this strip")
                .font(.headline)
            Text(entry.map { "#\($0.key)" } ?? "#\(ordinal)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 20) {
                if canRetry {
                    Button("Retry", action: onRetry)
                }
                if let originalPage {
                    Button("Open original") { openURL(originalPage) }
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(width: placeholderSize.width, height: placeholderSize.height)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("strip-failed-\(ordinal)")
    }
}

/// The tallest caption (title line and hover text) among the strips on screen, so the spread can
/// leave exactly that much room under the images.
struct CaptionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// End-of-comic card shown under the last strip.
struct CaughtUpCard: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Caught up")
                .font(.headline)
            Text("That's the latest strip.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("caught-up")
    }
}

// MARK: Decoding

/// Decoded strip images, so paging back and forth does not decode again. Decoding happens off the
/// main thread through `ImageCache.downsampled`.
final class DecodedImages: @unchecked Sendable {
    static let shared = DecodedImages()
    static let maxPixel = 4096

    enum Result { case image(CGImage), missing, undecodable }

    private let cache = NSCache<NSURL, CGImage>()

    init() { cache.countLimit = 16 }

    func image(_ file: URL) async -> Result {
        if let hit = cache.object(forKey: file as NSURL) { return .image(hit) }
        let result = await Task.detached(priority: .userInitiated) { () -> Result in
            guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
            guard let image = ImageCache.downsampled(file, maxPixel: Self.maxPixel) else { return .undecodable }
            return .image(image)
        }.value
        if case .image(let image) = result { cache.setObject(image, forKey: file as NSURL) }
        return result
    }
}

/// A cached image file, decoded off the main thread. A missing file (evicted from the cache) is
/// reported through `onMissing` so the strip can be reloaded.
private struct DecodedImage: View {
    let file: URL
    let label: String
    let onMissing: () -> Void
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(image, scale: 1, label: Text(label))
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle().fill(.quaternary.opacity(0.4))
            }
        }
        .task(id: file) {
            switch await DecodedImages.shared.image(file) {
            case .image(let decoded): image = decoded
            case .missing: image = nil; onMissing()
            case .undecodable: image = nil
            }
        }
    }
}

/// The bonus panel: drawn at the strip's width, height from its own aspect once decoded.
private struct BonusImage: View {
    let file: URL
    let width: CGFloat
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(image, scale: 1, label: Text("Bonus panel"))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: width, height: width * CGFloat(image.height) / CGFloat(max(image.width, 1)))
            } else {
                Color.clear.frame(width: width, height: 0)
            }
        }
        .task(id: file) {
            if case .image(let decoded) = await DecodedImages.shared.image(file) { image = decoded }
        }
        .accessibilityIdentifier("strip-bonus")
    }
}

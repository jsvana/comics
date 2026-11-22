import SwiftUI
import UIKit

/// The reader screen: the spread, tap and swipe navigation, chrome (top bar and scrubber), the
/// ⋯ menu, the "Back to #N" chip and the save warning.
struct ReaderView: View {
    let model: ReaderModel
    /// Shows a quiet "Offline" capsule while strips cannot be fetched.
    var offline = false
    let onClose: () -> Void

    @State private var chrome = false
    @State private var scrub: Double?
    @State private var askNumber = false
    @State private var numberText = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ReaderScroller(
                    content: SpreadContent(model: model, viewport: geo.size),
                    resetKey: model.first,
                    viewport: geo.size,
                    chromeVisible: chrome,
                    onAction: handle)
                tapZones
                if chrome { chromeBars }
                overlays
            }
            .onAppear { apply(geo.size) }
            .onChange(of: geo.size) { _, size in apply(size) }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        // Always hidden: showing it with the chrome would change the safe area, and so the
        // strip's size, every time the chrome is toggled.
        .statusBarHidden(true)
        .alert("Go to number", isPresented: $askNumber) {
            TextField("1–\(model.count)", text: $numberText)
                .keyboardType(.numberPad)
            Button("Go") {
                if let n = Int(numberText.trimmingCharacters(in: .whitespaces)) { model.go(to: n) }
                chrome = false
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func apply(_ size: CGSize) {
        model.canvas = size
        model.form = WindowForm(size: size)
    }

    private func handle(_ action: ReaderAction) {
        switch action {
        case .next:
            chrome = false
            model.next()
        case .previous:
            chrome = false
            model.previous()
        case .toggleChrome:
            withAnimation(.easeOut(duration: 0.18)) { chrome.toggle() }
        case .hideChrome:
            withAnimation(.easeOut(duration: 0.18)) { chrome = false }
        }
    }

    // MARK: Tap zones

    /// Accessibility handles for the three tap areas. They do not take touches themselves (the
    /// strip's scroll view does, so it can scroll and zoom); VoiceOver activates them directly.
    private var tapZones: some View {
        HStack(spacing: 0) {
            zone("reader-prev", "Previous") { handle(.previous) }
            zone("reader-middle", "Show controls") { handle(.toggleChrome) }
            zone("reader-next", "Next") { handle(.next) }
        }
        .allowsHitTesting(false)
    }

    private func zone(_ id: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(id)
            .accessibilityAction { action() }
    }

    // MARK: Chrome

    private var chromeBars: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        .transition(.opacity)
    }

    private var topBar: some View {
        ZStack {
            Text(model.def.title)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 110)
            HStack {
                Button(action: onClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Library")
                    }
                }
                .accessibilityIdentifier("reader-library")
                Spacer()
                menu
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar, ignoresSafeAreaEdges: .top)
    }

    private var menu: some View {
        Menu {
            Button("Go to number…", systemImage: "number") {
                numberText = ""
                askNumber = true
            }
            Button("First", systemImage: "backward.end") { jump(to: 1) }
            Button("Latest", systemImage: "forward.end") { jump(to: model.count) }
            if !model.history.isEmpty {
                Section("Back to") {
                    ForEach(Array(model.history.enumerated()), id: \.offset) { index, entry in
                        Button("Back to #\(entry.ordinal)", systemImage: "arrow.uturn.backward") {
                            if index == 0 { model.goBack() } else { model.go(to: entry.ordinal) }
                            chrome = false
                        }
                    }
                }
            }
            // One item per strip on screen, so the second strip of a spread can be opened too.
            Section {
                ForEach(model.spread, id: \.self) { ordinal in
                    if let page = model.originalPage(ordinal) {
                        Button("Open original page #\(ordinal)", systemImage: "safari") { openURL(page) }
                    }
                }
                ForEach(model.spread, id: \.self) { ordinal in
                    Button("Reload strip #\(ordinal)", systemImage: "arrow.clockwise") { model.retry(ordinal) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 32)
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("reader-menu")
    }

    private func jump(to ordinal: Int) {
        model.go(to: ordinal)
        chrome = false
    }

    private var bottomBar: some View {
        let shown = Int((scrub ?? Double(model.first)).rounded())
        return HStack(spacing: 14) {
            if model.count > 1 {
                Slider(
                    value: Binding(get: { scrub ?? Double(model.first) }, set: { scrub = $0 }),
                    in: 1...Double(model.count), step: 1
                ) { editing in
                    if !editing, let target = scrub {
                        scrub = nil
                        model.go(to: Int(target.rounded()))
                    }
                }
                .accessibilityIdentifier("reader-scrubber")
            } else {
                Spacer()
            }
            Text("\(shown) / \(model.count)")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("reader-position")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
    }

    // MARK: Chip and warning

    private var overlays: some View {
        VStack {
            if model.saveFailed {
                Label("Couldn't save your place", systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, chrome ? 64 : 12)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("save-warning")
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if offline {
                Label("Offline", systemImage: "wifi.slash")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, chrome ? 64 : 12)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("offline-banner")
            }
            Spacer(minLength: 0)
            if let target = model.backTarget {
                Button {
                    model.goBack()
                } label: {
                    Label("Back to #\(target)", systemImage: "arrow.uturn.backward")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("back-chip")
                .padding(.bottom, chrome ? 72 : 16)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.saveFailed)
    }
}

// MARK: - Spread

/// What the reader scrolls: the strips of the current spread, and the end card at the end.
private struct SpreadContent: View {
    let model: ReaderModel
    let viewport: CGSize

    private static let gutter: CGFloat = 16
    private static let verticalPadding: CGFloat = 8
    private static let chipRoom: CGFloat = 48
    /// Caption room assumed until the captions on screen have been measured.
    private static let defaultCaption: CGFloat = 46
    /// Space between an image and its caption.
    private static let captionGap: CGFloat = 6
    /// Never give captions more than this share of the screen; longer hover text scrolls instead.
    private static let maxCaptionShare: CGFloat = 0.4

    /// Height of the tallest caption on screen, measured; images are sized to leave room for it,
    /// so a strip and its hover text fit without a scroll whenever they can.
    @State private var measuredCaption: CGFloat?

    private var captionReserve: CGFloat {
        min((measuredCaption ?? Self.defaultCaption) + Self.captionGap, viewport.height * Self.maxCaptionShare)
    }

    var body: some View {
        VStack(spacing: 0) {
            spread
            // Room for the "Back to #N" chip, so it never covers a strip, its caption or the end card.
            if model.backTarget != nil { Color.clear.frame(height: Self.chipRoom) }
            if model.atEnd { CaughtUpCard() }
        }
        .padding(.vertical, Self.verticalPadding)
        .onPreferenceChange(CaptionHeightKey.self) { height in
            guard height > 0, abs(height - (measuredCaption ?? 0)) > 1 else { return }
            measuredCaption = height
        }
        .frame(width: viewport.width)
        .frame(minHeight: viewport.height)
        // Its own height, not the proposed one: the scroll view sizes itself from what this reports.
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var spread: some View {
        let height = viewport.height - 2 * Self.verticalPadding - (model.backTarget == nil ? 0 : Self.chipRoom)
        switch model.layout {
        case .single:
            if model.form == .wide {
                strip(model.first, box: CGSize(width: viewport.width - 2 * Self.gutter, height: height - captionReserve),
                      mode: .wideSingle, inset: 2)
            } else {
                strip(model.first, box: CGSize(width: viewport.width, height: height - captionReserve),
                      mode: .fitWidth, inset: 12)
            }
        case .sideBySide:
            let cell = CGSize(width: (viewport.width - 3 * Self.gutter) / 2, height: height - captionReserve)
            HStack(alignment: .top, spacing: Self.gutter) {
                strip(model.first, box: cell, mode: .fitBox, inset: 2)
                strip(model.first + 1, box: cell, mode: .fitBox, inset: 2)
            }
        case .stacked:
            let cell = CGSize(width: viewport.width - 2 * Self.gutter, height: (height - 2 * captionReserve - Self.gutter) / 2)
            VStack(spacing: Self.gutter) {
                strip(model.first, box: cell, mode: .fitBox, inset: 2)
                strip(model.first + 1, box: cell, mode: .fitBox, inset: 2)
            }
        }
    }

    private func strip(_ ordinal: Int, box: CGSize, mode: StripSizing.Mode, inset: CGFloat) -> some View {
        StripView(
            ordinal: ordinal, state: model.strips[ordinal], entry: model.entries[ordinal],
            box: box, mode: mode, captionInset: inset, originalPage: model.originalPage(ordinal),
            onRetry: { model.retry(ordinal) },
            onImageMissing: { model.imageMissing(ordinal) })
            .id(ordinal)
    }
}

// MARK: - Scrolling, zooming and taps

enum ReaderAction {
    case next, previous, toggleChrome, hideChrome
}

/// A UIKit scroll view around the SwiftUI spread: vertical scroll, pinch and double-tap zoom,
/// outer-third taps that scroll a screen before turning the page, and horizontal swipes.
private struct ReaderScroller<Content: View>: UIViewControllerRepresentable {
    let content: Content
    /// When this changes (a new spread), zoom and scroll position reset.
    let resetKey: Int
    let viewport: CGSize
    let chromeVisible: Bool
    let onAction: (ReaderAction) -> Void

    func makeUIViewController(context: Context) -> ReaderScrollController {
        ReaderScrollController()
    }

    func updateUIViewController(_ controller: ReaderScrollController, context: Context) {
        controller.onAction = onAction
        controller.chromeVisible = chromeVisible
        controller.setContent(AnyView(content))
        if controller.resetKey != resetKey || controller.viewport != viewport {
            controller.resetKey = resetKey
            controller.viewport = viewport
            controller.resetPosition()
        }
    }
}

final class ReaderScrollController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// Kept visible from the previous screen when a tap scrolls by a screen.
    private static let scrollOverlap: CGFloat = 48
    /// A second middle tap within this many seconds is a double tap (zoom), not a chrome toggle.
    private static let doubleTapWindow: TimeInterval = 0.28
    private static let doubleTapZoom: CGFloat = 2.5

    var onAction: (ReaderAction) -> Void = { _ in }
    var chromeVisible = false
    var resetKey: Int?
    var viewport: CGSize = .zero

    private let scroll = UIScrollView()
    private let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    private var contentSize: CGSize = .zero
    private var pendingMiddleTap: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scroll.backgroundColor = .clear
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        scroll.delaysContentTouches = false
        scroll.isDirectionalLockEnabled = true
        view.addSubview(scroll)

        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        scroll.addSubview(hosting.view)
        hosting.didMove(toParent: self)

        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            scroll.addGestureRecognizer(swipe)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.frame != view.bounds { scroll.frame = view.bounds }
    }

    func setContent(_ content: AnyView) {
        hosting.rootView = AnyView(
            content
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in self?.contentSizeChanged(size) }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { [weak self] value in self?.tapped(at: value.location) }))
    }

    func resetPosition() {
        pendingMiddleTap?.cancel()
        pendingMiddleTap = nil
        scroll.setZoomScale(1, animated: false)
        scroll.setContentOffset(.zero, animated: false)
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard size != contentSize, size.width > 0, size.height > 0 else { return }
        contentSize = size
        let zoom = scroll.zoomScale
        hosting.view.bounds = CGRect(origin: .zero, size: size)
        hosting.view.center = CGPoint(x: size.width * zoom / 2, y: size.height * zoom / 2)
        scroll.contentSize = CGSize(width: size.width * zoom, height: size.height * zoom)
    }

    // MARK: Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { hosting.view }

    private func toggleZoom(at point: CGPoint) {
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: true)
            return
        }
        let size = CGSize(width: scroll.bounds.width / Self.doubleTapZoom, height: scroll.bounds.height / Self.doubleTapZoom)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                    animated: true)
    }

    // MARK: Taps and swipes

    /// `point` is in the content's own (unzoomed) coordinates.
    private func tapped(at point: CGPoint) {
        if chromeVisible {
            onAction(.hideChrome)
            return
        }
        let x = point.x * scroll.zoomScale - scroll.contentOffset.x
        let fraction = x / max(scroll.bounds.width, 1)
        if fraction > 2.0 / 3.0 {
            forward()
        } else if fraction < 1.0 / 3.0 {
            backward()
        } else if let pending = pendingMiddleTap {
            pending.cancel()
            pendingMiddleTap = nil
            toggleZoom(at: point)
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingMiddleTap = nil
                self?.onAction(.toggleChrome)
            }
            pendingMiddleTap = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow, execute: work)
        }
    }

    /// Scrolls down a screen, or turns the page when already at the bottom.
    private func forward() {
        let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
        let y = scroll.contentOffset.y
        if y < maxY - 2 {
            let target = min(maxY, y + scroll.bounds.height - Self.scrollOverlap)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: true)
        } else {
            onAction(.next)
        }
    }

    /// Scrolls up a screen, or goes back a page when already at the top.
    private func backward() {
        let y = scroll.contentOffset.y
        if y > 2 {
            let target = max(0, y - (scroll.bounds.height - Self.scrollOverlap))
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: true)
        } else {
            onAction(.previous)
        }
    }

    @objc private func swiped(_ swipe: UISwipeGestureRecognizer) {
        onAction(swipe.direction == .left ? .next : .previous)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Swipes turn pages only when not zoomed in; zoomed, a horizontal drag pans.
        !(gestureRecognizer is UISwipeGestureRecognizer) || scroll.zoomScale <= 1.01
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

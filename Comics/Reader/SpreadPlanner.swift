import CoreGraphics

/// How the reader arranges the current strip and the one after it.
enum SpreadLayout: Equatable {
    case single, sideBySide, stacked
}

/// Decides whether two consecutive strips share the screen, and which way. Pure; sizes are image
/// pixel sizes.
///
/// Both arrangements are tried. Each strip is fitted into its half of the screen (side by side:
/// (canvas.width/2 - 24) x (canvas.height - 72); stacked: canvas.width x (canvas.height/2 - 44))
/// and compared with how large it would be alone on the screen. The arrangement whose smaller
/// strip keeps the larger share of its solo size wins. A pair is used only if that share is at
/// least 0.6 and every strip is at least 300 pt wide; otherwise the current strip is shown alone.
enum SpreadPlanner {
    private static let sideBySideGutter: CGFloat = 24
    private static let sideBySideVerticalChrome: CGFloat = 72
    private static let stackedVerticalChrome: CGFloat = 44
    /// The least share of its solo size a paired strip may have.
    private static let minShare: CGFloat = 0.6
    /// The least width, in points, a paired strip may have.
    private static let minWidth: CGFloat = 300

    static func layout(current: CGSize?, next: CGSize?, canvas: CGSize, form: WindowForm) -> SpreadLayout {
        guard form == .wide,
              let a = current, let b = next,
              a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return .single }
        let solo = CGSize(width: canvas.width, height: canvas.height - sideBySideVerticalChrome)
        let side = CGSize(width: canvas.width / 2 - sideBySideGutter, height: canvas.height - sideBySideVerticalChrome)
        let stack = CGSize(width: canvas.width, height: canvas.height / 2 - stackedVerticalChrome)

        /// The smaller strip's share of its solo size in `box`, or nil if a strip would be too small.
        func share(_ box: CGSize) -> CGFloat? {
            var least = CGFloat.infinity
            for strip in [a, b] {
                let width = fittedWidth(strip, in: box)
                let alone = fittedWidth(strip, in: solo)
                guard width >= minWidth, alone > 0 else { return nil }
                least = min(least, width / alone)
            }
            return least >= minShare ? least : nil
        }

        switch (share(side), share(stack)) {
        case (nil, nil): return .single
        case (.some, nil): return .sideBySide
        case (nil, .some): return .stacked
        case (.some(let across), .some(let down)): return across >= down ? .sideBySide : .stacked
        }
    }

    static func count(_ l: SpreadLayout) -> Int {
        l == .single ? 1 : 2
    }

    /// Width of `size` scaled (up or down) to fit inside `box`, aspect preserved.
    private static func fittedWidth(_ size: CGSize, in box: CGSize) -> CGFloat {
        guard box.width > 0, box.height > 0 else { return 0 }
        return size.width * min(box.width / size.width, box.height / size.height)
    }
}

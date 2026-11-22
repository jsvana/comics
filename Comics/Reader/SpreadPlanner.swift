import CoreGraphics

/// How the reader arranges the current strip and the one after it.
enum SpreadLayout: Equatable {
    case single, sideBySide, stacked
}

/// Decides whether two consecutive strips share the screen. Pure; sizes are image pixel sizes.
///
/// Tuned constants (the brief's starting values, kept after checking the designed
/// 951x669 canvas against the test cases):
/// - side by side: both width/height < 1.0 and each, fitted into
///   (canvas.width/2 - 24) x (canvas.height - 72), at least 400 pt wide
/// - stacked: both width/height >= 2.0 and each, fitted into
///   canvas.width x (canvas.height/2 - 44), at least 0.75 x canvas.width wide
/// - anything else, narrow form, an unknown size, or no next strip: single
enum SpreadPlanner {
    private static let sideBySideGutter: CGFloat = 24
    private static let sideBySideVerticalChrome: CGFloat = 72
    private static let sideBySideMinWidth: CGFloat = 400
    private static let stackedVerticalChrome: CGFloat = 44
    private static let stackedMinWidthFraction: CGFloat = 0.75
    private static let stackedMinRatio: CGFloat = 2.0

    static func layout(current: CGSize?, next: CGSize?, canvas: CGSize, form: WindowForm) -> SpreadLayout {
        guard form == .wide,
              let a = current, let b = next,
              a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return .single }
        let ratios = [a.width / a.height, b.width / b.height]

        if ratios.allSatisfy({ $0 < 1.0 }) {
            let box = CGSize(width: canvas.width / 2 - sideBySideGutter,
                             height: canvas.height - sideBySideVerticalChrome)
            if [a, b].allSatisfy({ fittedWidth($0, in: box) >= sideBySideMinWidth }) { return .sideBySide }
        }
        if ratios.allSatisfy({ $0 >= stackedMinRatio }) {
            let box = CGSize(width: canvas.width, height: canvas.height / 2 - stackedVerticalChrome)
            if [a, b].allSatisfy({ fittedWidth($0, in: box) >= stackedMinWidthFraction * canvas.width }) {
                return .stacked
            }
        }
        return .single
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

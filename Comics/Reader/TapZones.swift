import CoreGraphics
import SwiftUI

/// Where the reader's tap zones are, in the reader's own coordinates (origin at its top left).
///
/// - Wide (open Duo): the left third is Previous, the right third Next, the middle toggles the chrome.
/// - Narrow (closed Duo): both page turns sit in one column at the right edge, under the right
///   thumb. The column starts below the top safe-area inset (the camera) and ends at the bottom
///   one; its top third is Previous and the rest Next. A tap anywhere else toggles the chrome.
///
/// The zones overlay the strip; nothing is reserved for them.
enum TapZones {
    enum Zone: Equatable {
        case previous, next, toggleChrome
    }

    struct Frames: Equatable {
        var previous: CGRect
        var next: CGRect
        /// The main chrome-toggle area (the accessibility handle). Every tap outside `previous`
        /// and `next` toggles the chrome, including the safe-area ends of the narrow column.
        var toggleChrome: CGRect
    }

    /// Width of the narrow form's right-edge column.
    static let columnWidth: CGFloat = 96
    /// The share of the narrow column, from its top, that is Previous; Next takes the rest.
    static let previousShare: CGFloat = 1.0 / 3.0

    static func frames(for form: WindowForm, canvas: CGSize, safeArea: EdgeInsets) -> Frames {
        switch form {
        case .wide:
            let third = canvas.width / 3
            return Frames(
                previous: CGRect(x: 0, y: 0, width: third, height: canvas.height),
                next: CGRect(x: 2 * third, y: 0, width: canvas.width - 2 * third, height: canvas.height),
                toggleChrome: CGRect(x: third, y: 0, width: third, height: canvas.height))
        case .narrow:
            let width = min(columnWidth, canvas.width)
            let x = canvas.width - width
            let top = min(max(0, safeArea.top), canvas.height)
            let bottom = max(top, canvas.height - max(0, safeArea.bottom))
            let split = top + (bottom - top) * previousShare
            return Frames(
                previous: CGRect(x: x, y: top, width: width, height: split - top),
                next: CGRect(x: x, y: split, width: width, height: bottom - split),
                toggleChrome: CGRect(x: 0, y: 0, width: x, height: canvas.height))
        }
    }

    /// The zone a tap at `point` falls in.
    static func zone(at point: CGPoint, form: WindowForm, canvas: CGSize, safeArea: EdgeInsets) -> Zone {
        let frames = frames(for: form, canvas: canvas, safeArea: safeArea)
        if frames.next.contains(point) { return .next }
        if frames.previous.contains(point) { return .previous }
        return .toggleChrome
    }
}

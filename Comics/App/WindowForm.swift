import CoreGraphics

/// Layout form, chosen from the window size alone (never from the device idiom).
enum WindowForm: Equatable {
    case narrow
    case wide

    init(size: CGSize) {
        self = (size.width >= 700 && size.width > size.height) ? .wide : .narrow
    }
}

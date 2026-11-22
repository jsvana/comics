import CoreGraphics

/// Test and debugging launch arguments, e.g. `-canvas 951x669 -openComic qc -goto 2140`.
struct LaunchArgs: Equatable {
    var canvas: CGSize?
    var openComic: String?
    var goto: Int?
    var fixtureCatalog = false
    var resetFixture = false
    var icloud = true

    init(_ arguments: [String]) {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: "-" + key), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        func flag(_ key: String) -> Bool? {
            value(key).map { ["YES", "TRUE", "1"].contains($0.uppercased()) }
        }
        canvas = value("canvas").flatMap(Self.parseSize)
        openComic = value("openComic")
        goto = value("goto").flatMap { Int($0) }
        fixtureCatalog = flag("fixtureCatalog") ?? false
        resetFixture = flag("resetFixture") ?? false
        icloud = flag("icloud") ?? true
    }

    private static func parseSize(_ spec: String) -> CGSize? {
        let parts = spec.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
}

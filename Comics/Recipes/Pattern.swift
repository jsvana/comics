import Foundation

/// The single place catalog regexes are compiled and run.
enum Pattern {
    private static let options: NSRegularExpression.Options = [.dotMatchesLineSeparators]

    /// Names of `(?<name>...)` groups in the pattern.
    private static func groupNames(_ pattern: String) -> [String] {
        guard let finder = try? NSRegularExpression(pattern: #"\(\?<([A-Za-z][A-Za-z0-9]*)>"#) else { return [] }
        let ns = pattern as NSString
        return finder.matches(in: pattern, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1))
        }
    }

    private static func compile(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    /// The first match's named group, or nil when nothing matches or the group did not participate.
    static func first(_ pattern: String, in text: String, group: String) -> String? {
        guard let regex = compile(pattern) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let r = m.range(withName: group)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }

    /// Every match, in document order, as a dictionary of the named groups that participated.
    static func all(_ pattern: String, in text: String) -> [[String: String]] {
        guard let regex = compile(pattern) else { return [] }
        let names = groupNames(pattern)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            var out: [String: String] = [:]
            for name in names {
                let r = m.range(withName: name)
                if r.location != NSNotFound { out[name] = ns.substring(with: r) }
            }
            return out
        }
    }

    private static let named: [String: String] = [
        "amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": "\u{00A0}",
    ]

    /// Decodes numeric (`&#8217;`, `&#x2019;`) and the common named HTML entities.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&"), let regex = try? NSRegularExpression(pattern: #"&(?:#(\d+)|#[xX]([0-9A-Fa-f]+)|([A-Za-z]+));"#) else { return s }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
            var replacement: String?
            if m.range(at: 1).location != NSNotFound, let v = UInt32(ns.substring(with: m.range(at: 1))) {
                replacement = Unicode.Scalar(v).map { String($0) }
            } else if m.range(at: 2).location != NSNotFound, let v = UInt32(ns.substring(with: m.range(at: 2)), radix: 16) {
                replacement = Unicode.Scalar(v).map { String($0) }
            } else if m.range(at: 3).location != NSNotFound {
                replacement = named[ns.substring(with: m.range(at: 3))]
            }
            out += replacement ?? ns.substring(with: m.range)
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Resolves a possibly relative or protocol-relative reference against a page URL.
    static func resolve(_ ref: String, against base: URL) -> URL? {
        URL(string: ref, relativeTo: base)?.absoluteURL
    }
}

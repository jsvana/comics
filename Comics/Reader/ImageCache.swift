import CryptoKit
import Foundation
import ImageIO

enum ImageCacheError: Error, Equatable {
    /// The server answered 2xx with no body. Nothing is stored.
    case emptyBody
}

/// Strip images on disk under `directory/<comic>/`, evicting least recently used files when the
/// total goes over `capBytes`. Decoding goes through ImageIO so huge images are never loaded whole.
actor ImageCache {
    private let http: HTTPFetching
    private let directory: URL
    private let capBytes: Int
    private var lastStamp = Date.distantPast

    init(http: HTTPFetching, directory: URL, capBytes: Int = 500_000_000) {
        self.http = http
        self.directory = directory
        self.capBytes = capBytes
    }

    /// The cached file for `url`, downloading it first if needed. Throws `HTTPError` on a non-2xx
    /// status, `ImageCacheError.emptyBody` for an empty body, and the transport error otherwise.
    func file(for url: URL, comic: String) async throws -> URL {
        let target = location(for: url, comic: comic)
        if FileManager.default.fileExists(atPath: target.path) {
            touch(target)
            return target
        }
        let (data, _) = try await http.get(url)
        guard !data.isEmpty else { throw ImageCacheError.emptyBody }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        touch(target)
        evict(keeping: target)
        return target
    }

    /// The cached file for `url` if it is already on disk; never downloads. For library thumbnails.
    func cachedFile(for url: URL, comic: String) -> URL? {
        let target = location(for: url, comic: comic)
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    /// Deletes the cached copy of `url`, if any.
    func remove(_ url: URL, comic: String) {
        try? FileManager.default.removeItem(at: location(for: url, comic: comic))
    }

    func totalBytes() -> Int {
        entries().reduce(0) { $0 + $1.size }
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Decoding

    /// Pixel dimensions from the file header, without decoding the image.
    static func pixelSize(of file: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// The first frame, scaled down so neither side exceeds `maxPixel`; never scaled up.
    static func downsampled(_ file: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = pixelSize(of: file) else { return nil }
        if Int(max(size.width, size.height)) <= maxPixel {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Files

    private func location(for url: URL, comic: String) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.lowercased()
        let safeExt = (1...5).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? ext : "img"
        let folder = String(comic.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
        return directory.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("\(digest).\(safeExt)")
    }

    /// Marks `file` as used now. Stamps strictly increase so rapid use keeps its order.
    private func touch(_ file: URL) {
        let stamp = max(Date(), lastStamp.addingTimeInterval(0.001))
        lastStamp = stamp
        try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
    }

    private struct Entry { let url: URL; let size: Int; let used: Date }

    private func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return [] }
        var result: [Entry] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            result.append(Entry(url: url, size: v.fileSize ?? 0, used: v.contentModificationDate ?? .distantPast))
        }
        return result
    }

    private func evict(keeping keep: URL) {
        var all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > capBytes else { return }
        all.sort { $0.used < $1.used }
        for entry in all where total > capBytes {
            if entry.url.standardizedFileURL == keep.standardizedFileURL { continue }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

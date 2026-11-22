import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Comics

final class ImageCacheTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("imagecache-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Image generation

    static func png(width: Int, height: Int, shade: UInt8 = 128) -> Data {
        let space = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: CGFloat(shade) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func gif(frames: Int) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, frames, nil)!
        for i in 0..<frames {
            let space = CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(red: i == 0 ? 1 : 0, green: 0, blue: i == 0 ? 0 : 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        }
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func serve(_ http: StubHTTP, _ url: String, _ body: Data) {
        http.routes[url] = (200, [:], body)
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: Cache

    func testSecondFetchIsServedFromDisk() async throws {
        let http = StubHTTP()
        serve(http, "https://img.test/a.png", Self.png(width: 20, height: 10))
        let cache = ImageCache(http: http, directory: dir)
        let url = URL(string: "https://img.test/a.png")!
        let first = try await cache.file(for: url, comic: "c")
        let second = try await cache.file(for: url, comic: "c")
        XCTAssertEqual(first, second)
        XCTAssertEqual(http.requested.count, 1)
        XCTAssertTrue(first.path.contains("/c/"))
    }

    func testEvictsLeastRecentlyUsedOverCap() async throws {
        let http = StubHTTP()
        let body = Self.png(width: 64, height: 64)
        let urls = (1...5).map { URL(string: "https://img.test/\($0).png")! }
        for u in urls { serve(http, u.absoluteString, body) }
        let cache = ImageCache(http: http, directory: dir, capBytes: body.count * 3 + body.count / 2)
        for u in urls.prefix(3) { _ = try await cache.file(for: u, comic: "c") }
        _ = try await cache.file(for: urls[0], comic: "c")  // 1 is now newer than 2 and 3
        for u in urls.suffix(2) { _ = try await cache.file(for: u, comic: "c") }

        let total = await cache.totalBytes()
        XCTAssertLessThanOrEqual(total, body.count * 3 + body.count / 2)
        http.routes = [:]  // anything not on disk would now fail
        for u in [urls[0], urls[3], urls[4]] { _ = try await cache.file(for: u, comic: "c") }
        for u in [urls[1], urls[2]] {
            do { _ = try await cache.file(for: u, comic: "c"); XCTFail("\(u) should have been evicted") } catch {}
        }
    }

    func testWebPFixtureDecodes() throws {
        let file = try write(StubHTTP.fixture("smbc-strip.webp"), "smbc.webp")
        let size = try XCTUnwrap(ImageCache.pixelSize(of: file))
        XCTAssertGreaterThan(size.width, 0)
        let image = try XCTUnwrap(ImageCache.downsampled(file, maxPixel: 100))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 100)
    }

    func testGIFUsesFirstFrame() throws {
        let file = try write(Self.gif(frames: 2), "a.gif")
        XCTAssertEqual(ImageCache.pixelSize(of: file), CGSize(width: 40, height: 30))
        let image = try XCTUnwrap(ImageCache.downsampled(file, maxPixel: 4096))
        XCTAssertEqual(image.width, 40)
    }

    func testSmallImageIsNotUpscaled() throws {
        let file = try write(Self.png(width: 50, height: 20), "s.png")
        let image = try XCTUnwrap(ImageCache.downsampled(file, maxPixel: 4096))
        XCTAssertEqual(image.width, 50)
        XCTAssertEqual(image.height, 20)
    }

    // Uses a 2000x20000 PNG as specified (flat grey, so it encodes small).
    func testTallImageIsDownsampled() throws {
        let file = try write(Self.png(width: 2000, height: 20000), "tall.png")
        XCTAssertEqual(ImageCache.pixelSize(of: file), CGSize(width: 2000, height: 20000))
        let image = try XCTUnwrap(ImageCache.downsampled(file, maxPixel: 4096))
        XCTAssertLessThanOrEqual(image.height, 4096)
        XCTAssertLessThanOrEqual(image.width, 4096)
    }

    func testUndecodableFileGivesNil() throws {
        let file = try write(Data("not an image".utf8), "x.png")
        XCTAssertNil(ImageCache.pixelSize(of: file))
        XCTAssertNil(ImageCache.downsampled(file, maxPixel: 100))
    }

    func testEmptyBodyThrowsAndLeavesNoFile() async throws {
        let http = StubHTTP()
        serve(http, "https://img.test/z.png", Data())
        let cache = ImageCache(http: http, directory: dir)
        do {
            _ = try await cache.file(for: URL(string: "https://img.test/z.png")!, comic: "c")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ImageCacheError, .emptyBody)
        }
        let total = await cache.totalBytes()
        XCTAssertEqual(total, 0)
    }

    func testStatusErrorPropagates() async throws {
        let cache = ImageCache(http: StubHTTP(), directory: dir)
        do {
            _ = try await cache.file(for: URL(string: "https://img.test/missing.png")!, comic: "c")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? HTTPError, .status(404))
        }
    }

    func testClearRemovesEverything() async throws {
        let http = StubHTTP()
        serve(http, "https://img.test/a.png", Self.png(width: 8, height: 8))
        let cache = ImageCache(http: http, directory: dir)
        _ = try await cache.file(for: URL(string: "https://img.test/a.png")!, comic: "c")
        await cache.clear()
        let total = await cache.totalBytes()
        XCTAssertEqual(total, 0)
    }
}

import ImageIO
import XCTest
@testable import Comics

/// Live check of every catalog recipe against the real sites. Opt in with
/// `TEST_RUNNER_COMICS_LIVE=1` (xcodebuild hands it to the test process as `COMICS_LIVE`); without
/// it every test here is skipped, so the normal suite never touches the network.
///
/// For each comic: build the whole index, then extract, download and decode the first, middle and
/// last strip. Requests go through `PoliteHTTPClient` (one at a time per host, 250 ms apart).
final class RecipeHealthTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["COMICS_LIVE"] == "1",
                          "Set TEST_RUNNER_COMICS_LIVE=1 to check the catalog against the live sites.")
        continueAfterFailure = true
    }

    private func catalog() throws -> Catalog {
        let url = try XCTUnwrap(Bundle(for: CatalogStore.self).url(forResource: "catalog", withExtension: "json"))
        return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    func testEveryCatalogComic() async throws {
        let catalog = try catalog()
        XCTAssertFalse(catalog.comics.isEmpty)
        for def in catalog.comics { await check(def) }
    }

    private func check(_ def: ComicDef) async {
        let http = PoliteHTTPClient()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recipe-health-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = ImageCache(http: http, directory: dir)
        do {
            let entries = try await IndexFetcher(http: http).newEntries(def.index, knownCount: 0, lastKey: nil)
            XCTAssertGreaterThan(entries.count, 0, "\(def.id): empty index")
            guard !entries.isEmpty else { return }
            var report = "LIVE \(def.id): \(entries.count) strips"
            let picks = [("first", 0), ("middle", entries.count / 2), ("last", entries.count - 1)]
            for (label, i) in picks {
                let entry = entries[i]
                do {
                    let details = try await StripExtractor(http: http).details(def.strip, entry: entry)
                    let file = try await images.file(for: details.image, comic: def.id)
                    let size = ImageCache.pixelSize(of: file)
                    XCTAssertNotNil(ImageCache.downsampled(file, maxPixel: 64), "\(def.id) \(label) (\(entry.key)): image does not decode")
                    XCTAssertNotNil(size, "\(def.id) \(label) (\(entry.key)): image does not decode: \(details.image)")
                    if let size {
                        XCTAssertGreaterThan(size.width, 0)
                        XCTAssertGreaterThan(size.height, 0)
                        report += "\nLIVE \(def.id) \(label) #\(i + 1) key=\(entry.key) \(Int(size.width))x\(Int(size.height)) \(details.image.absoluteString)"
                    }
                } catch {
                    XCTFail("\(def.id) \(label) (\(entry.key)): \(error)")
                }
            }
            print(report)
        } catch {
            XCTFail("\(def.id): index failed: \(error)")
        }
    }
}

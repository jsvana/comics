import XCTest
@testable import Comics

final class PatternTests: XCTestCase {
    func testDecodeEntities() {
        XCTAssertEqual(Pattern.decodeEntities("it&#8217;s &quot;x&quot; &amp; y"), "it’s \"x\" & y")
        XCTAssertEqual(Pattern.decodeEntities("a&#x2019;b &unknown; &"), "a’b &unknown; &")
    }

    func testResolveRelative() {
        let base = URL(string: "https://www.questionablecontent.net/view.php?comic=100")!
        XCTAssertEqual(Pattern.resolve("./comics/100.png", against: base)?.absoluteString,
                       "https://www.questionablecontent.net/comics/100.png")
        let proto = Pattern.resolve("//imgs.xkcd.com/a.png", against: base)
        XCTAssertEqual(proto?.scheme, "https")
        XCTAssertEqual(proto?.absoluteString, "https://imgs.xkcd.com/a.png")
    }

    func testMatchesAcrossLines() {
        XCTAssertEqual(Pattern.first("<a>(?<v>.*?)</a>", in: "<a>x\ny</a>", group: "v"), "x\ny")
        XCTAssertEqual(Pattern.all("(?<key>\\d)(?<title>x)?", in: "1x2").map { $0["title"] }, ["x", nil])
    }
}

final class IndexFetcherTests: XCTestCase {
    /// A comic from the bundled catalog, or the saved Dumbing of Age definition (`doa-comic.json`):
    /// its site refuses the app's client name for images, so it left the catalog, but the
    /// WordPress index recipe keeps its offline tests.
    private func comic(_ id: String) throws -> ComicDef {
        if id == "doa" { return try JSONDecoder().decode(ComicDef.self, from: StubHTTP.fixture("doa-comic.json")) }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "catalog", withExtension: "json"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        return try XCTUnwrap(catalog.comics.first { $0.id == id })
    }

    private func route(_ body: Data, headers: [String: String] = [:]) -> StubHTTP.Route {
        (status: 200, headers: headers, body: body)
    }

    private func xkcdLatest() throws -> Int {
        let json = try JSONSerialization.jsonObject(with: StubHTTP.fixture("xkcd-latest.json")) as? [String: Any]
        return try XCTUnwrap(json?["num"] as? Int)
    }

    func testXkcdFromScratch() async throws {
        let num = try xkcdLatest()
        let def = try comic("xkcd")
        let http = StubHTTP(routes: ["https://xkcd.com/info.0.json": route(StubHTTP.fixture("xkcd-latest.json"))])
        let entries = try await IndexFetcher(http: http).newEntries(def.index, knownCount: 0, lastKey: nil, progress: nil)
        XCTAssertEqual(entries.count, num - 1)
        XCTAssertEqual(entries.first?.key, "1")
        XCTAssertFalse(entries.contains { $0.key == "404" })
        XCTAssertEqual(entries.last?.key, String(num))
    }

    func testNumberedIncremental() async throws {
        let num = try xkcdLatest()
        let def = try comic("xkcd")
        let http = StubHTTP(routes: ["https://xkcd.com/info.0.json": route(StubHTTP.fixture("xkcd-latest.json"))])
        let entries = try await IndexFetcher(http: http)
            .newEntries(def.index, knownCount: num - 1 - 3, lastKey: String(num - 3), progress: nil)
        XCTAssertEqual(entries.map(\.key), [String(num - 2), String(num - 1), String(num)])
    }

    func testQCLatestFromFrontPage() async throws {
        let def = try comic("qc")
        let front = StubHTTP.fixture("qc-front.html")
        let html = String(decoding: front, as: UTF8.self)
        let expected = try XCTUnwrap(Pattern.first("<img id=\"strip\" src=\"[^\"]*/comics/(?<n>\\d+)\\.png\"", in: html, group: "n"))
        let http = StubHTTP(routes: ["https://www.questionablecontent.net/": route(front)])
        let entries = try await IndexFetcher(http: http).newEntries(def.index, knownCount: 0, lastKey: nil, progress: nil)
        XCTAssertEqual(entries.last?.key, expected)
        XCTAssertEqual(entries.count, Int(expected))
    }

    func testQCLatestAcceptsAnyImageExtension() async throws {
        let def = try comic("qc")
        let html = String(decoding: StubHTTP.fixture("qc-front.html"), as: UTF8.self)
        let expected = try XCTUnwrap(Pattern.first("<img id=\"strip\" src=\"[^\"]*/comics/(?<n>\\d+)\\.png\"", in: html, group: "n"))
        let jpeg = html.replacingOccurrences(of: "/comics/\(expected).png", with: "/comics/\(expected).jpg")
        XCTAssertNotEqual(jpeg, html)
        let http = StubHTTP(routes: ["https://www.questionablecontent.net/": route(Data(jpeg.utf8))])
        let entries = try await IndexFetcher(http: http).newEntries(def.index, knownCount: 0, lastKey: nil, progress: nil)
        XCTAssertEqual(entries.last?.key, expected)
    }

    private let doaBase = "https://www.dumbingofage.com/wp-json/wp/v2/comic?per_page=100&order=asc&orderby=date&_fields=id,slug,date,title,link"

    func testWordPressPagesWithOffset() async throws {
        let def = try comic("doa")
        let tail = """
        [{"id":900,"date":"2020-01-01T00:01:00","slug":"it-s","link":"https:\\/\\/www.dumbingofage.com\\/comic\\/it-s\\/","title":{"rendered":"It&#8217;s here"}},
         {"id":901,"date":"2020-01-02T00:01:00","slug":"last","link":"https:\\/\\/www.dumbingofage.com\\/comic\\/last\\/","title":{"rendered":"Last"}}]
        """
        let http = StubHTTP(routes: [
            doaBase + "&offset=0": route(StubHTTP.fixture("doa-page1.json")),
            doaBase + "&offset=100": route(Data(tail.utf8)),
        ])
        let entries = try await IndexFetcher(http: http).newEntries(def.index, knownCount: 0, lastKey: nil, progress: nil)
        XCTAssertEqual(entries.count, 102)
        XCTAssertEqual(entries.first?.key, "home")
        XCTAssertEqual(entries.first?.page?.absoluteString, "https://www.dumbingofage.com/comic/home/")
        XCTAssertEqual(entries[100].key, "it-s")
        XCTAssertEqual(entries[100].title, "It’s here")
        XCTAssertEqual(http.requested.map(\.absoluteString), [doaBase + "&offset=0", doaBase + "&offset=100"])
    }

    func testWordPressIncremental() async throws {
        let def = try comic("doa")
        let http = StubHTTP(routes: [doaBase + "&offset=100": route(Data("[]".utf8))])
        let entries = try await IndexFetcher(http: http).newEntries(def.index, knownCount: 100, lastKey: "x", progress: nil)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(http.requested.map(\.absoluteString), [doaBase + "&offset=100"])
    }

    func testPBFArchive() async throws {
        let def = try comic("pbf")
        let http = StubHTTP(routes: ["https://pbfcomics.com/comics/": route(StubHTTP.fixture("pbf-archive.html"))])
        let entries = try await IndexFetcher(http: http).newEntries(def.index, knownCount: 0, lastKey: nil, progress: nil)
        let keys = entries.map(\.key)
        XCTAssertTrue((200...400).contains(keys.count), "\(keys.count)")
        XCTAssertFalse(keys.contains { $0.contains("feed") })
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(keys.first, "new-herald-galactus")
        // The newest comic is first in the full list (the featured teasers repeat it); the oldest
        // slug is last in the archive's own order, so after reversal the newest is last.
        XCTAssertEqual(keys.last, "substitute-torture")
        XCTAssertEqual(entries.first?.page?.absoluteString, "https://pbfcomics.com/comics/new-herald-galactus/")
    }

    func testLinkListOldestFirstOptions() async throws {
        let html = """
        <select><option value="comic/a">A</option><option value="comic/b">B &amp; C</option>
        <option value="comic/c">C</option><option value="comic/b">B again</option></select>
        """
        let recipe = IndexRecipe.linkList(.init(
            url: URL(string: "https://example.com/archive")!,
            itemPattern: "<option value=\"(?<key>comic/[^\"]+)\">(?<title>[^<]*)",
            pageTemplate: "https://example.com/{key}", newestFirst: false))
        let http = StubHTTP(routes: ["https://example.com/archive": route(Data(html.utf8))])
        let entries = try await IndexFetcher(http: http).newEntries(recipe, knownCount: 0, lastKey: nil, progress: nil)
        XCTAssertEqual(entries.map(\.key), ["comic/a", "comic/b", "comic/c"])
        XCTAssertEqual(entries.map(\.title), ["A", "B & C", "C"])
        XCTAssertEqual(entries.map { $0.page?.absoluteString },
                       ["https://example.com/comic/a", "https://example.com/comic/b", "https://example.com/comic/c"])
        let later = try await IndexFetcher(http: http).newEntries(recipe, knownCount: 1, lastKey: "comic/a", progress: nil)
        XCTAssertEqual(later.map(\.key), ["comic/b", "comic/c"])
    }

    func testLinkListLastKeyMissingThrows() async throws {
        let def = try comic("pbf")
        let http = StubHTTP(routes: ["https://pbfcomics.com/comics/": route(StubHTTP.fixture("pbf-archive.html"))])
        do {
            _ = try await IndexFetcher(http: http).newEntries(def.index, knownCount: 5, lastKey: "not-there", progress: nil)
            XCTFail("expected lastKeyMissing")
        } catch {
            XCTAssertEqual(error as? IndexError, .lastKeyMissing)
        }
    }

    func testNoMatchThrows() async throws {
        let def = try comic("xkcd")
        let http = StubHTTP(routes: ["https://xkcd.com/info.0.json": route(Data())])
        do {
            _ = try await IndexFetcher(http: http).newEntries(def.index, knownCount: 0, lastKey: nil, progress: nil)
            XCTFail("expected noMatch")
        } catch {
            XCTAssertEqual(error as? IndexError, .noMatch)
        }
    }

    func testLinkListSortsByOrderCaptureAndKeepsHighestForRepeats() async throws {
        // Out of reading order, with "b" listed twice: its higher number is its real place.
        let html = """
        <option value='30' data-u='/c/c/'>C</option>
        <option value='2' data-u='/c/b/'>B early</option>
        <option value='10' data-u='/c/a/'>A</option>
        <option value='20' data-u='/c/b/'>B</option>
        """
        let http = StubHTTP()
        http.routes["https://example.com/list"] = (200, [:], Data(html.utf8))
        let recipe = IndexRecipe.linkList(.init(
            url: URL(string: "https://example.com/list")!,
            itemPattern: "<option value='(?<order>\\d+)' data-u='/c/(?<key>[^/]+)/'>(?<title>[^<]*)",
            pageTemplate: "https://example.com/c/{key}/", newestFirst: false))
        let all = try await IndexFetcher(http: http).newEntries(recipe, knownCount: 0, lastKey: nil, progress: nil)
        XCTAssertEqual(all.map(\.key), ["a", "b", "c"])
        XCTAssertEqual(all[1].title, "B")
        let after = try await IndexFetcher(http: http).newEntries(recipe, knownCount: 2, lastKey: "b", progress: nil)
        XCTAssertEqual(after.map(\.key), ["c"])
    }
}

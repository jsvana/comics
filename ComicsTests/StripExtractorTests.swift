import XCTest
@testable import Comics

final class StripExtractorTests: XCTestCase {
    private func recipe(_ id: String) throws -> StripRecipe {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "catalog", withExtension: "json"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        return try XCTUnwrap(catalog.comics.first { $0.id == id }).strip
    }

    private func stub(_ url: String, fixture: String) -> StubHTTP {
        StubHTTP(routes: [url: (200, [:], StubHTTP.fixture(fixture))])
    }

    private func stub(_ url: String, html: String) -> StubHTTP {
        StubHTTP(routes: [url: (200, [:], Data(html.utf8))])
    }

    func testXkcd1() async throws {
        let http = stub("https://xkcd.com/1/info.0.json", fixture: "xkcd-1.json")
        let d = try await StripExtractor(http: http).details(recipe("xkcd"), entry: IndexEntry(key: "1"))
        XCTAssertEqual(d.image.host, "imgs.xkcd.com")
        XCTAssertEqual(d.title, "Barrel - Part 1")
        XCTAssertEqual(d.hover, "Don't we all.")
        XCTAssertEqual(d.page.absoluteString, "https://xkcd.com/1/")
    }

    func testQC100() async throws {
        let http = stub("https://www.questionablecontent.net/view.php?comic=100", fixture: "qc-100.html")
        let d = try await StripExtractor(http: http).details(recipe("qc"), entry: IndexEntry(key: "100"))
        XCTAssertEqual(d.image.absoluteString, "https://www.questionablecontent.net/comics/100.png")
    }

    func testQC4000() async throws {
        let http = stub("https://www.questionablecontent.net/view.php?comic=4000", fixture: "qc-4000.html")
        let d = try await StripExtractor(http: http).details(recipe("qc"), entry: IndexEntry(key: "4000"))
        XCTAssertEqual(d.image.host, "www.questionablecontent.net")
        XCTAssertTrue(d.image.path.hasPrefix("/comics/4000."), d.image.path)
    }

    func testDoA() async throws {
        let page = "https://www.dumbingofage.com/comic/home/"
        let http = stub(page, fixture: "doa-strip.html")
        let entry = IndexEntry(key: "home", page: URL(string: page))
        let d = try await StripExtractor(http: http).details(recipe("doa"), entry: entry)
        XCTAssertTrue(d.image.path.contains("/wp-content/uploads/"), d.image.path)
        XCTAssertNotNil(d.image.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}-"#, options: .regularExpression), d.image.lastPathComponent)
        XCTAssertFalse(d.hover?.isEmpty ?? true)
    }

    func testPBF() async throws {
        let page = "https://pbfcomics.com/comics/new-herald-galactus/"
        let http = stub(page, fixture: "pbf-strip.html")
        let entry = IndexEntry(key: "new-herald-galactus", page: URL(string: page))
        let d = try await StripExtractor(http: http).details(recipe("pbf"), entry: entry)
        XCTAssertEqual(d.image.absoluteString,
                       "https://pbfcomics.com/wp-content/uploads/2017/05/GCPBF-New_Herald_of_Galactus-for-Marvel.png")
    }

    /// Plain `src` markup (no lazy loading) with the comic first after the title, as a newer page may use.
    func testPBFPlainSrcMarkup() async throws {
        let page = "https://pbfcomics.com/comics/newest/"
        let html = """
        <img width="79" height="30" src="https://pbfcomics.com/wp-content/uploads/2016/08/nav_home_white.png" class="wp-post-image" />
        <h1 class="pbf-comic-title">Newest</h1>
        <div class="entry-content"><img src="https://pbfcomics.com/wp-content/uploads/2026/11/PBF-Newest.png" width="400" alt="Newest" /></div>
        <img width="100" height="100" data-src="https://pbfcomics.com/wp-content/uploads/2026/07/Thumb.png" class="wp-post-image lazyload" />
        """
        let entry = IndexEntry(key: "newest", page: URL(string: page))
        let d = try await StripExtractor(http: stub(page, html: html)).details(recipe("pbf"), entry: entry)
        XCTAssertEqual(d.image.absoluteString, "https://pbfcomics.com/wp-content/uploads/2026/11/PBF-Newest.png")
    }

    func testMessyMarkup() async throws {
        let strip = StripRecipe.HTMLStrip(
            url: "{page}",
            imagePattern: #"<img[^>]*src='(?<v>[^']+)'"#,
            titlePattern: nil,
            hoverPattern: #"<img[^>]*title="(?<v>[^"]*)""#,
            bonusPattern: nil)
        let page = "https://example.com/p/1"
        let html = #"<img title="it&#8217;s &quot;fine&quot;" src='//cdn.example.com/a b.png'>"#
        let d = try await StripExtractor(http: stub(page, html: html))
            .details(.html(strip), entry: IndexEntry(key: "1", page: URL(string: page)))
        XCTAssertEqual(d.image.absoluteString, "https://cdn.example.com/a%20b.png")
        XCTAssertEqual(d.hover, "it’s \"fine\"")
    }

    func testBonusAndHoverInline() async throws {
        let strip = StripRecipe.HTMLStrip(
            url: "{page}",
            imagePattern: #"<img[^>]*src="(?<v>[^"]+)"[^>]*id="cc-comic""#,
            titlePattern: nil,
            hoverPattern: #"<img title="(?<v>[^"]*)"[^>]*id="cc-comic""#,
            bonusPattern: #"<div id="aftercomic"><img src='(?<v>[^']+)'"#)
        let page = "https://example.com/comic/a"
        let html = """
        <img title="hover &amp; more" src="/comics/a.png" id="cc-comic" />
        <p>text</p>
        <div id="aftercomic"><img src='/comics/a-after.png'></div>
        """
        let d = try await StripExtractor(http: stub(page, html: html))
            .details(.html(strip), entry: IndexEntry(key: "a", page: URL(string: page)))
        XCTAssertEqual(d.image.absoluteString, "https://example.com/comics/a.png")
        XCTAssertEqual(d.hover, "hover & more")
        XCTAssertEqual(d.bonus?.absoluteString, "https://example.com/comics/a-after.png")
    }

    func testNoImageThrows() async throws {
        let http = stub("https://www.questionablecontent.net/view.php?comic=1", html: "<html></html>")
        do {
            _ = try await StripExtractor(http: http).details(recipe("qc"), entry: IndexEntry(key: "1"))
            XCTFail("expected noImage")
        } catch {
            XCTAssertEqual(error as? StripError, .noImage)
        }
    }

    func test404Throws() async throws {
        do {
            _ = try await StripExtractor(http: StubHTTP()).details(recipe("qc"), entry: IndexEntry(key: "9"))
            XCTFail("expected http(404)")
        } catch {
            XCTAssertEqual(error as? StripError, .http(404))
        }
    }
}

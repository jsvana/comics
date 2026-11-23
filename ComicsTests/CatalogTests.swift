import XCTest
@testable import Comics

final class CatalogTests: XCTestCase {
    private func bundledData() throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "catalog", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func bundledCatalog() throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: bundledData())
    }

    func testDecodesTheComicsInOrder() throws {
        let catalog = try bundledCatalog()
        XCTAssertEqual(catalog.schema, Catalog.supportedSchema)
        XCTAssertEqual(catalog.comics.map(\.id), ["xkcd", "qc", "doa", "pbf", "smbc", "aurora"])
    }

    func testHostExceptionsAreOnlyOnTheComicsThatNeedThem() throws {
        let comics = Dictionary(uniqueKeysWithValues: try bundledCatalog().comics.map { ($0.id, $0) })
        XCTAssertEqual(comics["doa"]?.browserHosts, ["www.dumbingofage.com", "dumbingofage.com"])
        XCTAssertEqual(comics["smbc"]?.lenientHosts, ["www.smbc-comics.com", "smbc-comics.com"])
        for id in ["xkcd", "qc", "pbf"] {
            XCTAssertNil(comics[id]?.browserHosts, id)
            XCTAssertNil(comics[id]?.lenientHosts, id)
        }
        XCTAssertNil(comics["doa"]?.lenientHosts)
        XCTAssertNil(comics["smbc"]?.browserHosts)
    }

    func testIndexKinds() throws {
        let comics = Dictionary(uniqueKeysWithValues: try bundledCatalog().comics.map { ($0.id, $0) })
        guard case .numbered(let n) = comics["xkcd"]?.index else { return XCTFail("xkcd not numbered") }
        XCTAssertEqual(n.skip, [404])
        guard case .linkList(let l) = comics["pbf"]?.index else { return XCTFail("pbf not linkList") }
        XCTAssertTrue(l.newestFirst)
    }

    func testEveryPatternCompiles() throws {
        var patterns: [String] = []
        for comic in try bundledCatalog().comics {
            switch comic.index {
            case .numbered(let n): patterns.append(n.latestPattern)
            case .wordpress: break
            case .linkList(let l): patterns.append(l.itemPattern)
            }
            if case .html(let h) = comic.strip {
                patterns += [h.imagePattern] + [h.titlePattern, h.hoverPattern, h.bonusPattern].compactMap { $0 }
            }
        }
        XCTAssertFalse(patterns.isEmpty)
        for p in patterns {
            XCTAssertNoThrow(try NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]), p)
        }
    }

    func testUnknownKindFailsWholeCatalog() throws {
        var json = try XCTUnwrap(String(data: bundledData(), encoding: .utf8))
        json = json.replacingOccurrences(of: "\"kind\": \"linkList\"", with: "\"kind\": \"mystery\"")
        XCTAssertThrowsError(try JSONDecoder().decode(Catalog.self, from: Data(json.utf8))) { error in
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
    }

    func testRoundTrip() throws {
        let catalog = try bundledCatalog()
        let again = try JSONDecoder().decode(Catalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(again, catalog)
    }
}

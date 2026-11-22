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

    func testDecodesFiveComicsInOrder() throws {
        let catalog = try bundledCatalog()
        XCTAssertEqual(catalog.schema, Catalog.supportedSchema)
        XCTAssertEqual(catalog.comics.map(\.id), ["xkcd", "qc", "doa", "smbc", "pbf"])
    }

    func testIndexKinds() throws {
        let comics = Dictionary(uniqueKeysWithValues: try bundledCatalog().comics.map { ($0.id, $0) })
        guard case .numbered(let n) = comics["xkcd"]?.index else { return XCTFail("xkcd not numbered") }
        XCTAssertEqual(n.skip, [404])
        guard case .wordpress = comics["doa"]?.index else { return XCTFail("doa not wordpress") }
        guard case .linkList(let l) = comics["smbc"]?.index else { return XCTFail("smbc not linkList") }
        XCTAssertFalse(l.newestFirst)
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
        json = json.replacingOccurrences(of: "\"kind\": \"wordpress\"", with: "\"kind\": \"mystery\"")
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

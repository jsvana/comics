import XCTest
@testable import Comics

final class AppEnvironmentTests: XCTestCase {
    private func catalog(version: Int, ids: [String]) -> Catalog {
        Catalog(schema: 1, version: version, comics: ids.map { id in
            ComicDef(
                id: id, title: id, author: "A", home: URL(string: "https://stub.test/")!, about: "", shape: .wide,
                index: .numbered(.init(latestURL: URL(string: "https://stub.test/latest")!, latestPattern: "(?<n>\\d+)", first: 1, skip: [])),
                strip: .json(.init(url: "https://stub.test/{key}.json", page: "https://stub.test/{key}", image: "img", title: nil, hover: nil)))
        })
    }

    func testRestoreSeesTheCatalogAfterTheRemoteCheck() async {
        final class Box: @unchecked Sendable { var catalog: Catalog; var events: [String] = []; init(_ c: Catalog) { catalog = c } }
        let box = Box(catalog(version: 1, ids: ["a"]))
        let newer = catalog(version: 2, ids: ["a", "b"])
        await AppEnvironment.activate(
            purge: { box.events.append("purge") },
            checkCatalog: { box.events.append("check"); box.catalog = newer },
            currentCatalog: { box.catalog },
            restore: { box.events.append("restore \($0.version)") },
            refreshLibrary: { box.events.append("refresh") })
        XCTAssertEqual(box.events, ["purge", "check", "restore 2", "refresh"])
    }

    func testRemoteIsNotPersistedInFixtureMode() throws {
        let suite = "AppEnvironmentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(string: "https://fixture.invalid/remote-catalog.json")!
        AppEnvironment.persistRemote(url, fixtureMode: true, defaults: defaults)
        XCTAssertNil(defaults.string(forKey: CatalogStore.remoteDefaultsKey))
        AppEnvironment.persistRemote(url, fixtureMode: false, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: CatalogStore.remoteDefaultsKey), url.absoluteString)
        AppEnvironment.persistRemote(nil, fixtureMode: true, defaults: defaults)
        XCTAssertNotNil(defaults.string(forKey: CatalogStore.remoteDefaultsKey), "fixture mode leaves the saved value alone")
        AppEnvironment.persistRemote(CatalogStore.defaultRemote, fixtureMode: false, defaults: defaults)
        XCTAssertNil(defaults.string(forKey: CatalogStore.remoteDefaultsKey), "the default address is stored as no choice")
    }

    func testParseRemoteAcceptsOnlyHTTPS() {
        XCTAssertNotNil(CatalogStore.parseRemote(" https://example.com/catalog.json "))
        XCTAssertNil(CatalogStore.parseRemote("http://example.com/catalog.json"))
        XCTAssertNil(CatalogStore.parseRemote("file:///etc/passwd"))
        XCTAssertNil(CatalogStore.parseRemote("ftp://example.com/c.json"))
        XCTAssertNil(CatalogStore.parseRemote("https://"))
        XCTAssertNil(CatalogStore.parseRemote("example.com/catalog.json"))
    }
}

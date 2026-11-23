import XCTest
import GRDB
@testable import Comics

final class CloudMirrorTests: XCTestCase {
    private let latest = "https://stub.test/latest"

    private func def(id: String = "num", skip: [Int] = []) -> ComicDef {
        ComicDef(
            id: id, title: "Numbered", author: "A", home: URL(string: "https://stub.test/")!, about: "",
            shape: .wide,
            index: .numbered(.init(latestURL: URL(string: latest)!, latestPattern: "\"num\":\\s*(?<n>\\d+)", first: 1, skip: skip)),
            strip: .json(.init(url: "https://stub.test/{key}.json", page: "https://stub.test/{key}", image: "img", title: nil, hover: nil)))
    }

    private struct Rig {
        let cloud: MemoryCloud
        let library: LibraryStore
        let places: PlaceKeeper
        let mirror: CloudMirror
    }

    private func rig(latestNumber: Int = 10, cloud: MemoryCloud = MemoryCloud()) throws -> Rig {
        let http = StubHTTP()
        http.routes[latest] = (200, [:], Data("{\"num\": \(latestNumber)}".utf8))
        let db = try Comics.Database(path: nil)
        let library = LibraryStore(db: db, index: IndexFetcher(http: http))
        let places = PlaceKeeper(db: db)
        return Rig(cloud: cloud, library: library, places: places,
                   mirror: CloudMirror(cloud: cloud, library: library, places: places))
    }

    private func catalog(_ defs: ComicDef...) -> Catalog { Catalog(schema: 1, version: 1, comics: defs) }

    private func put(_ cloud: MemoryCloud, _ place: SavedPlace) throws {
        cloud.set(try SavedPlace.encoder().encode(place), forKey: "place.\(place.comicID)")
    }

    /// The pushed place for `id`, once every push queued so far has reached the cloud.
    private func saved(_ r: Rig, _ id: String) throws -> SavedPlace {
        r.mirror.flush()
        return try SavedPlace.decoder().decode(SavedPlace.self, from: try XCTUnwrap(r.cloud.data(forKey: "place.\(id)")))
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    func testPushOnEveryBookmarkChange() async throws {
        let r = try rig()
        try await r.library.add(def(), start: .first)
        r.places.step("num", to: 4)
        let p = try saved(r, "num")
        XCTAssertEqual(p.ordinal, 4)
        XCTAssertEqual(p.key, "4")
        XCTAssertFalse(p.removed)
        r.places.jump("num", to: 8)
        let q = try saved(r, "num")
        XCTAssertEqual(q.ordinal, 8)
        XCTAssertEqual(q.history.map(\.ordinal), [4])
    }

    func testPushOnAddAndRemove() async throws {
        let r = try rig()
        try await r.library.add(def(), start: .latest)
        XCTAssertEqual(try saved(r, "num").ordinal, 10)
        r.library.remove("num")
        let p = try saved(r, "num")
        XCTAssertTrue(p.removed)
        XCTAssertEqual(p.ordinal, 10)
    }

    func testRestoreOnlyWhenNoLocalRow() async throws {
        let r = try rig()
        try await r.library.add(def(), start: .first)
        r.places.step("num", to: 3)
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 9, key: "9", history: [], removed: false))
        await r.mirror.restoreMissing(catalog: catalog(def()))
        XCTAssertEqual(r.places.bookmark("num"), 3)
    }

    func testRestoreLeavesLocallyRemovedComicAlone() async throws {
        let r = try rig()
        try await r.library.add(def(), start: .first)
        r.library.remove("num")
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 9, key: "9", history: [], removed: false))
        await r.mirror.restoreMissing(catalog: catalog(def()))
        XCTAssertEqual(r.places.bookmark("num"), 1)
        XCTAssertTrue(r.library.activeIDs().isEmpty)
    }

    func testRestoreAddsMissingComic() async throws {
        let r = try rig()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 4, key: "4", history: [JumpEntry(ordinal: 2, key: "2", at: when)], removed: false))
        await r.mirror.restoreMissing(catalog: catalog(def()))
        XCTAssertEqual(r.library.activeIDs(), ["num"])
        XCTAssertEqual(r.places.bookmark("num"), 4)
        XCTAssertEqual(r.places.history("num"), [JumpEntry(ordinal: 2, key: "2", at: when)])
        // The cloud copy was not overwritten with a start-of-comic bookmark along the way.
        XCTAssertEqual(try saved(r, "num").ordinal, 4)
    }

    func testRestoreFollowsKeyNotOrdinal() async throws {
        let r = try rig()
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 4, key: "4", history: [], removed: false))
        await r.mirror.restoreMissing(catalog: catalog(def(skip: [3])))
        XCTAssertEqual(r.places.bookmark("num"), 3)  // key "4" is now strip number 3
    }

    func testRestoreClampsWhenKeyGone() async throws {
        let r = try rig()
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 50, key: "zzz", history: [], removed: false))
        await r.mirror.restoreMissing(catalog: catalog(def()))
        XCTAssertEqual(r.places.bookmark("num"), 10)
    }

    func testRestoreOnEmptyIndexLeavesBookmarkAtOne() async throws {
        let r = try rig(latestNumber: 0)
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 7, key: "7", history: [], removed: false))
        await r.mirror.restoreMissing(catalog: catalog(def()))
        XCTAssertEqual(r.places.bookmark("num"), 1)
        XCTAssertEqual(try saved(r, "num").ordinal, 7)  // cloud copy untouched
    }

    func testRestoreIgnoresRemovedAndUnknownComics() async throws {
        let r = try rig()
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 4, key: "4", history: [], removed: true))
        try put(r.cloud, SavedPlace(comicID: "ghost", ordinal: 4, key: "4", history: [], removed: false))
        await r.mirror.restoreMissing(catalog: catalog(def()))
        XCTAssertFalse(r.library.hasRow("num"))
        XCTAssertFalse(r.library.hasRow("ghost"))
    }

    func testCorruptCloudDataIgnored() async throws {
        let r = try rig()
        r.cloud.set(Data("not json".utf8), forKey: "place.x")
        r.cloud.set(Data("{}".utf8), forKey: "place.num")
        await r.mirror.restoreMissing(catalog: catalog(def(), def(id: "x")))
        XCTAssertTrue(r.library.activeIDs().isEmpty)
    }

    func testExportApplyRoundTrip() async throws {
        let a = try rig()
        try await a.library.add(def(), start: .first)
        a.places.jump("num", to: 6)
        a.places.step("num", to: 7)
        let data = try ProgressFile.export(library: a.library, places: a.places)
        let list = try SavedPlace.decoder().decode([SavedPlace].self, from: data)
        XCTAssertEqual(list.map(\.comicID), ["num"])
        XCTAssertEqual(list.first?.ordinal, 7)

        let b = try rig()
        try await ProgressFile.apply(data, catalog: catalog(def()), library: b.library, places: b.places)
        XCTAssertEqual(b.places.bookmark("num"), 7)
        XCTAssertEqual(b.places.history("num").map(\.ordinal), [1])
    }

    func testApplyOnExistingComicPushesHistory() async throws {
        let r = try rig()
        try await r.library.add(def(), start: .first)
        r.places.step("num", to: 3)
        let file = try SavedPlace.encoder().encode([SavedPlace(comicID: "num", ordinal: 9, key: "9", history: [], removed: false)])
        try await ProgressFile.apply(file, catalog: catalog(def()), library: r.library, places: r.places)
        XCTAssertEqual(r.places.bookmark("num"), 9)
        XCTAssertEqual(r.places.history("num").map(\.ordinal), [3])
        XCTAssertEqual(try saved(r, "num").ordinal, 9)
    }

    func testApplyRejectsCorruptFile() async throws {
        let r = try rig()
        do {
            try await ProgressFile.apply(Data("nope".utf8), catalog: catalog(def()), library: r.library, places: r.places)
            XCTFail("expected a throw")
        } catch {}
    }

    func testApplyReportsComicsThatCouldNotBeRestored() async throws {
        let r = try rig()
        let http = StubHTTP()  // every index request 404s
        let db = try Comics.Database(path: nil)
        let library = LibraryStore(db: db, index: IndexFetcher(http: http))
        let places = PlaceKeeper(db: db)
        let file = try SavedPlace.encoder().encode([
            SavedPlace(comicID: "num", ordinal: 3, key: "3", history: [], removed: false),
            SavedPlace(comicID: "gone", ordinal: 3, key: "3", history: [], removed: false),
            SavedPlace(comicID: "old", ordinal: 3, key: "3", history: [], removed: true),
        ])
        let failed = try await ProgressFile.apply(file, catalog: catalog(def()), library: library, places: places)
        XCTAssertEqual(failed, ["num", "gone"])
        XCTAssertTrue(library.activeIDs().isEmpty)

        let ok = try await ProgressFile.apply(file, catalog: catalog(def()), library: r.library, places: r.places)
        XCTAssertEqual(ok, ["gone"])
        XCTAssertEqual(r.places.bookmark("num"), 3)
    }

    // MARK: A fresh install whose iCloud copy arrives late

    func testAddingAComicWithNoLocalRecordTakesThePlaceFromTheCloud() async throws {
        let r = try rig()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 7, key: "7", history: [JumpEntry(ordinal: 2, key: "2", at: when)], removed: false))
        try await r.library.add(def(), start: .first)  // the user adds it by hand before restore ran
        XCTAssertEqual(r.places.bookmark("num"), 7)
        XCTAssertEqual(r.places.history("num"), [JumpEntry(ordinal: 2, key: "2", at: when)])
        let p = try saved(r, "num")
        XCTAssertEqual(p.ordinal, 7, "the cloud copy was not overwritten with the starting strip")
        XCTAssertEqual(p.history.map(\.ordinal), [2])
    }

    func testAddingNeverPushesTheStartingStripOverACloudPlace() async throws {
        let r = try rig()
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 7, key: "7", history: [], removed: false))
        let seen = Locked<[Int]>([])
        r.cloud.onSet = { key, data in
            guard key == "place.num", let data, let p = try? SavedPlace.decoder().decode(SavedPlace.self, from: data) else { return }
            seen.mutate { $0.append(p.ordinal) }
        }
        try await r.library.add(def(), start: .latest)
        r.mirror.flush()
        XCTAssertFalse(seen.value.contains(10), "pushed \(seen.value)")
        XCTAssertEqual(r.places.bookmark("num"), 7)
    }

    func testAddingFollowsTheCloudKeyWhenTheIndexShifted() async throws {
        let r = try rig()
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 4, key: "4", history: [], removed: false))
        try await r.library.add(def(skip: [3]), start: .first)
        XCTAssertEqual(r.places.bookmark("num"), 3)  // key "4" is strip number 3 here
    }

    func testAddingIgnoresACloudPlaceMarkedRemoved() async throws {
        let r = try rig()
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 7, key: "7", history: [], removed: true))
        try await r.library.add(def(), start: .first)
        XCTAssertEqual(r.places.bookmark("num"), 1)
        XCTAssertEqual(try saved(r, "num").ordinal, 1)
    }

    func testReAddingARemovedComicKeepsTheLocalPlace() async throws {
        let r = try rig()
        try await r.library.add(def(), start: .first)
        r.places.step("num", to: 3)
        r.library.remove("num")
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 9, key: "9", history: [], removed: false))
        try await r.library.add(def(), start: .first)
        XCTAssertEqual(r.places.bookmark("num"), 3, "a local record exists, so local wins")
        XCTAssertEqual(try saved(r, "num").ordinal, 3)
    }

    func testExternalChangeRestoresComicsOnlyTheCloudKnows() async throws {
        let r = try rig()
        let reloads = Locked(0)
        let follower = Task {
            await r.mirror.followExternalChanges(catalog: { self.catalog(self.def()) }, then: { reloads.mutate { $0 += 1 } })
        }
        defer { follower.cancel() }
        // First activation found an empty store; the iCloud copy arrives afterwards.
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 6, key: "6", history: [], removed: false))
        r.cloud.simulateExternalChange()
        await waitUntil("restored and reloaded") { reloads.value >= 1 }
        XCTAssertEqual(r.library.activeIDs(), ["num"])
        XCTAssertEqual(r.places.bookmark("num"), 6)
        XCTAssertEqual(try saved(r, "num").ordinal, 6)
    }

    func testExternalChangeLeavesExistingComicsAlone() async throws {
        let r = try rig()
        try await r.library.add(def(), start: .first)
        r.places.step("num", to: 3)
        let reloads = Locked(0)
        let follower = Task {
            await r.mirror.followExternalChanges(catalog: { self.catalog(self.def()) }, then: { reloads.mutate { $0 += 1 } })
        }
        defer { follower.cancel() }
        try put(r.cloud, SavedPlace(comicID: "num", ordinal: 9, key: "9", history: [], removed: false))
        r.cloud.simulateExternalChange()
        await waitUntil("handled") { reloads.value >= 1 }
        XCTAssertEqual(r.places.bookmark("num"), 3)
    }

    // MARK: Pushing off the main thread

    func testPushRunsOffTheCallingThreadAndTheLastWriteWins() async throws {
        let r = try rig()
        try await r.library.add(def(), start: .first)
        r.mirror.flush()
        let threads = Locked<[Bool]>([])
        r.cloud.onSet = { _, _ in threads.mutate { $0.append(Thread.isMainThread) } }
        await MainActor.run {
            for n in 2...8 { r.places.step("num", to: n) }
        }
        XCTAssertEqual(try saved(r, "num").ordinal, 8)
        XCTAssertFalse(threads.value.isEmpty)
        XCTAssertFalse(threads.value.contains(true), "a cloud write ran on the main thread")
    }
}

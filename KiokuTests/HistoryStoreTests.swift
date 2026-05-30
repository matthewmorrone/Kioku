import XCTest
@testable import Kioku

// Pins the HistoryStore lookup-recency contract: each canonical_entry_id appears at most
// once, most-recent record wins, the list is bounded by maxEntries, and bulk operations
// converge to the same shape as N single operations. UserDefaults is the persistence
// store, so tests scrub the known storage key around each case rather than injecting a
// fake — keeps the production code untouched and matches the pattern other Store tests
// in this target should follow when they're written.
@MainActor
final class HistoryStoreTests: XCTestCase {

    // Mirrored from HistoryStore.storageKey — duplicated here so tests don't require
    // making the production constant internal.
    private static let storageKey = "kioku.history.v1"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        try await super.tearDown()
    }

    // record(canonicalEntryID:surface:) prepends to the head of the list.
    func testRecordPrependsNewEntry() {
        let store = HistoryStore()
        store.record(canonicalEntryID: 1, surface: "猫")
        store.record(canonicalEntryID: 2, surface: "犬")
        XCTAssertEqual(store.entries.map(\.canonicalEntryID), [2, 1])
    }

    // Re-recording an existing canonical_entry_id moves it to the head without duplicating it.
    func testRecordMovesExistingEntryToFront() {
        let store = HistoryStore()
        store.record(canonicalEntryID: 1, surface: "猫")
        store.record(canonicalEntryID: 2, surface: "犬")
        store.record(canonicalEntryID: 1, surface: "猫")
        XCTAssertEqual(store.entries.map(\.canonicalEntryID), [1, 2])
        XCTAssertEqual(store.entries.count, 2)
    }

    // The list is capped at maxEntries (200); recording past that drops the oldest tail.
    func testRecordEnforcesMaxEntriesCap() {
        let store = HistoryStore()
        for i in 1...250 {
            store.record(canonicalEntryID: Int64(i), surface: "s\(i)")
        }
        XCTAssertEqual(store.entries.count, 200)
        // Most recent (250) at the head, oldest survivor (51) at the tail.
        XCTAssertEqual(store.entries.first?.canonicalEntryID, 250)
        XCTAssertEqual(store.entries.last?.canonicalEntryID, 51)
    }

    // remove(id:) drops one entry; others are untouched.
    func testRemoveByIdDropsOneEntry() {
        let store = HistoryStore()
        store.record(canonicalEntryID: 1, surface: "a")
        store.record(canonicalEntryID: 2, surface: "b")
        store.record(canonicalEntryID: 3, surface: "c")
        store.remove(id: 2)
        XCTAssertEqual(store.entries.map(\.canonicalEntryID), [3, 1])
    }

    // remove(ids:) drops every listed entry in one pass.
    func testRemoveByIdsDropsManyEntries() {
        let store = HistoryStore()
        store.record(canonicalEntryID: 1, surface: "a")
        store.record(canonicalEntryID: 2, surface: "b")
        store.record(canonicalEntryID: 3, surface: "c")
        store.record(canonicalEntryID: 4, surface: "d")
        store.remove(ids: [2, 4])
        XCTAssertEqual(store.entries.map(\.canonicalEntryID), [3, 1])
    }

    // clear() empties the list.
    func testClearEmptiesTheList() {
        let store = HistoryStore()
        store.record(canonicalEntryID: 1, surface: "a")
        store.record(canonicalEntryID: 2, surface: "b")
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    // replaceAll dedupes by canonical_entry_id (most recent timestamp wins), bounds to
    // maxEntries, and orders the result newest-first.
    func testReplaceAllDedupesBoundsAndSortsNewestFirst() {
        let store = HistoryStore()
        let older = Date(timeIntervalSince1970: 1_000_000)
        let newer = Date(timeIntervalSince1970: 2_000_000)
        store.replaceAll(with: [
            HistoryEntry(canonicalEntryID: 1, surface: "old-猫", lookedUpAt: older),
            HistoryEntry(canonicalEntryID: 1, surface: "new-猫", lookedUpAt: newer),
            HistoryEntry(canonicalEntryID: 2, surface: "犬", lookedUpAt: older),
        ])
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.map(\.canonicalEntryID), [1, 2])
        XCTAssertEqual(store.entries.first?.surface, "new-猫")
    }

    // Persistence: a fresh store loads back the entries the previous instance wrote.
    func testEntriesSurviveAcrossInstances() {
        let writer = HistoryStore()
        writer.record(canonicalEntryID: 7, surface: "蝶")
        writer.record(canonicalEntryID: 8, surface: "鳥")
        let reader = HistoryStore()
        XCTAssertEqual(reader.entries.map(\.canonicalEntryID), [8, 7])
    }

    // MARK: - Re-point

    // Re-pointing a history row swaps its entry id + surface in place, keeping list position.
    func testRepointKeepsPositionAndUpdatesSurface() {
        let store = HistoryStore()
        store.record(canonicalEntryID: 1, surface: "A")
        store.record(canonicalEntryID: 2, surface: "下")
        store.record(canonicalEntryID: 3, surface: "C") // entries now [3, 2, 1]

        store.repoint(historyID: "e:2", toEntryID: 99, surface: "する")

        XCTAssertEqual(store.entries.map(\.canonicalEntryID), [3, 99, 1], "middle row re-pointed in place")
        XCTAssertEqual(store.entries.first { $0.canonicalEntryID == 99 }?.surface, "する")
    }

    // If the target id already has a row, re-point folds it into the re-pointed slot so the
    // composite id ("e:<id>") stays unique (a duplicate would collide in the List's ForEach).
    func testRepointDedupesAgainstExistingTargetRow() {
        let store = HistoryStore()
        store.record(canonicalEntryID: 1, surface: "A")
        store.record(canonicalEntryID: 2, surface: "下") // entries [2, 1]

        store.repoint(historyID: "e:2", toEntryID: 1, surface: "する")

        XCTAssertEqual(store.entries.filter { $0.canonicalEntryID == 1 }.count, 1, "no duplicate target row")
        XCTAssertEqual(store.entries.map(\.canonicalEntryID), [1], "source slot kept, stale target folded out")
    }
}

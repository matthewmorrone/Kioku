import XCTest
@testable import Kioku

// Characterizes SavedKanjiStore — the saved-kanji lifecycle and the SavedKanjiStorage
// normalization it depends on. Each test gets its own UserDefaults suite (UUID-based
// suite name) so cases never collide with .standard or with each other in parallel.
// Mirrors WordsStoreTests' pattern so the two stores are tested with the same
// rigour (Invariant 8 — every Store needs a *Tests.swift sibling).
@MainActor
final class SavedKanjiStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private static let storageKey = "kioku.savedKanji.test"

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "kioku-savedKanji-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults, "Failed to construct test UserDefaults suite")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeStore() -> SavedKanjiStore {
        SavedKanjiStore(userDefaults: defaults, storageKey: Self.storageKey)
    }

    // Drains the off-main persist queue BEFORE constructing the reader, so the
    // reader's init-time UserDefaults load observes the previous writer's writes.
    // Required because persist is async; flushing after the reader has been built
    // is too late — the reader has already read. Production never needs this:
    // the app launches long after the queue has drained.
    private func makeReaderStore() -> SavedKanjiStore {
        SavedKanjiStore.flushPendingWritesForTesting()
        return makeStore()
    }

    // MARK: - Initialization

    // A fresh suite produces an empty store — guards against leaked state from other tests.
    func testInitFromEmptyStorageIsEmpty() {
        XCTAssertTrue(makeStore().kanji.isEmpty)
    }

    // MARK: - Toggle

    // toggle() on an empty store adds the kanji and returns true.
    func testToggleAddsKanjiWhenAbsent() {
        let store = makeStore()
        let nowSaved = store.toggle(literal: "雨")
        XCTAssertTrue(nowSaved)
        XCTAssertEqual(store.kanji.map(\.literal), ["雨"])
    }

    // toggle() on an existing kanji removes it and returns false.
    func testToggleRemovesKanjiWhenPresent() {
        let store = makeStore()
        _ = store.toggle(literal: "雨")
        let nowSaved = store.toggle(literal: "雨")
        XCTAssertFalse(nowSaved)
        XCTAssertTrue(store.kanji.isEmpty)
    }

    // Toggling attribution: the sourceNoteID is captured when adding so the kanji
    // remembers which note surfaced it.
    func testToggleCapturesSourceNoteID() {
        let store = makeStore()
        let noteID = UUID()
        _ = store.toggle(literal: "雨", sourceNoteID: noteID)
        XCTAssertEqual(store.kanji.first?.sourceNoteIDs, [noteID])
    }

    // MARK: - Save (idempotent add)

    // save() on an absent kanji creates a record with the supplied memberships.
    func testSaveCreatesRecordWithMemberships() {
        let store = makeStore()
        let listID = UUID()
        store.save(literal: "雪", wordListIDs: [listID])
        XCTAssertEqual(store.kanji.first?.wordListIDs, [listID])
    }

    // save() on an existing kanji unions sourceNoteIDs + wordListIDs and preserves
    // savedAt — the user's earliest "I saved this" timestamp wins, attribution accretes.
    func testSaveOnExistingMergesMemberships() {
        let store = makeStore()
        let firstNote = UUID()
        let secondNote = UUID()
        let firstList = UUID()
        let secondList = UUID()
        store.save(literal: "火", sourceNoteIDs: [firstNote], wordListIDs: [firstList])
        let firstSavedAt = store.kanji.first!.savedAt
        store.save(literal: "火", sourceNoteIDs: [secondNote], wordListIDs: [secondList])
        let merged = store.kanji.first!
        XCTAssertEqual(Set(merged.sourceNoteIDs), Set([firstNote, secondNote]))
        XCTAssertEqual(Set(merged.wordListIDs), Set([firstList, secondList]))
        XCTAssertEqual(merged.savedAt, firstSavedAt)
    }

    // MARK: - Remove

    // remove() drops the kanji if present; safe no-op when absent.
    func testRemove() {
        let store = makeStore()
        _ = store.toggle(literal: "水")
        store.remove(literal: "水")
        XCTAssertTrue(store.kanji.isEmpty)
        store.remove(literal: "水")
        XCTAssertTrue(store.kanji.isEmpty)
    }

    // MARK: - List membership

    // setListMembership(true) adds the list ID; idempotent on repeat adds.
    func testSetListMembershipAddsAndDeduplicates() {
        let store = makeStore()
        _ = store.toggle(literal: "日")
        let listID = UUID()
        store.setListMembership(literal: "日", listID: listID, isMember: true)
        store.setListMembership(literal: "日", listID: listID, isMember: true)
        XCTAssertEqual(store.kanji.first?.wordListIDs, [listID])
    }

    // setListMembership(false) removes the list ID; safe no-op when not a member.
    func testSetListMembershipRemoves() {
        let store = makeStore()
        _ = store.toggle(literal: "月")
        let listID = UUID()
        store.setListMembership(literal: "月", listID: listID, isMember: true)
        store.setListMembership(literal: "月", listID: listID, isMember: false)
        XCTAssertEqual(store.kanji.first?.wordListIDs, [])
    }

    // MARK: - Personal note

    // setPersonalNote stores and trims whitespace; empty/whitespace-only resolves to nil.
    func testSetPersonalNoteTrimsAndClearsWhitespace() {
        let store = makeStore()
        _ = store.toggle(literal: "星")
        store.setPersonalNote(literal: "星", note: "  evening sky  ")
        XCTAssertEqual(store.kanji.first?.personalNote, "evening sky")
        store.setPersonalNote(literal: "星", note: "   ")
        XCTAssertNil(store.kanji.first?.personalNote)
    }

    // MARK: - Persistence roundtrip

    // Writes through one store flush off-main and load back via a fresh store, with
    // memberships preserved across the encode/decode/normalize cycle.
    func testPersistenceRoundtripPreservesMemberships() {
        let writer = makeStore()
        let listID = UUID()
        let noteID = UUID()
        _ = writer.toggle(literal: "雷", sourceNoteID: noteID)
        writer.setListMembership(literal: "雷", listID: listID, isMember: true)
        writer.setPersonalNote(literal: "雷", note: "thunder kami")

        let reader = makeReaderStore()
        XCTAssertEqual(reader.kanji.count, 1)
        let loaded = reader.kanji.first!
        XCTAssertEqual(loaded.literal, "雷")
        XCTAssertEqual(loaded.sourceNoteIDs, [noteID])
        XCTAssertEqual(loaded.wordListIDs, [listID])
        XCTAssertEqual(loaded.personalNote, "thunder kami")
    }

    // MARK: - Normalization

    // normalizedEntries coalesces duplicate literals, unions memberships, keeps the
    // earliest savedAt — guards the contract that callers (CSV import, future bulk
    // operations) won't silently lose attribution by writing duplicates.
    func testNormalizedEntriesMergesDuplicates() {
        let first = SavedKanji(literal: "海", sourceNoteIDs: [UUID()], wordListIDs: [UUID()], savedAt: Date(timeIntervalSince1970: 100))
        let second = SavedKanji(literal: "海", sourceNoteIDs: [UUID()], wordListIDs: [UUID()], savedAt: Date(timeIntervalSince1970: 200))
        let merged = SavedKanjiStorage.normalizedEntries([first, second])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.sourceNoteIDs.count, 2)
        XCTAssertEqual(merged.first?.wordListIDs.count, 2)
        XCTAssertEqual(merged.first?.savedAt, first.savedAt)
    }
}

import XCTest
@testable import Kioku

// Characterizes WordsStore — the saved-word lifecycle and the SavedWordStorage normalization
// it depends on. Each test gets its own UserDefaults suite (via UUID-based suite name) so
// cases never collide with .standard or with each other when run in parallel.
@MainActor
final class WordsStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private static let storageKey = "kioku.words.test"

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "kioku-words-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults, "Failed to construct test UserDefaults suite")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeStore() -> WordsStore {
        WordsStore(userDefaults: defaults, storageKey: Self.storageKey)
    }

    // Drains the off-main persist queue so subsequent makeStore() calls observe the
    // latest writes. Required after the persist path moved off-main; without it the
    // reader can construct before the background JSON encode + UserDefaults write
    // completes. Production never needs this — the app launches long after the queue
    // has drained.
    private func makeReaderStore() -> WordsStore {
        WordsStore.flushPendingWritesForTesting()
        return makeStore()
    }

    // MARK: - Initialization

    // A fresh suite produces an empty store with no leaked entries from prior runs.
    func testInitFromEmptyStorageIsEmpty() {
        let store = makeStore()
        XCTAssertTrue(store.words.isEmpty)
    }

    // Stored entries load back exactly as written through a previous store instance — the
    // writer/reader contract that the rest of the persistence tests rely on.
    func testInitLoadsPersistedEntries() {
        let writer = makeStore()
        writer.replaceAll(with: [
            SavedWord(canonicalEntryID: 1, surface: "猫"),
            SavedWord(canonicalEntryID: 2, surface: "犬"),
        ])

        let reader = makeReaderStore()
        XCTAssertEqual(reader.words.map(\.canonicalEntryID), [1, 2])
        XCTAssertEqual(reader.words.map(\.surface), ["猫", "犬"])
    }

    // MARK: - replaceAll + persist

    // replaceAll(with: []) clears everything — used by the Settings "wipe all words" action.
    func testReplaceAllWithEmptyClearsStore() {
        let store = makeStore()
        store.replaceAll(with: [SavedWord(canonicalEntryID: 1, surface: "猫")])
        XCTAssertEqual(store.words.count, 1)

        store.replaceAll(with: [])
        XCTAssertTrue(store.words.isEmpty)

        // And it persists.
        let reader = makeReaderStore()
        XCTAssertTrue(reader.words.isEmpty)
    }

    // MARK: - remove(id:) and remove(ids:)

    func testRemoveByIdDropsOneEntry() {
        let store = makeStore()
        store.replaceAll(with: [
            SavedWord(canonicalEntryID: 1, surface: "a"),
            SavedWord(canonicalEntryID: 2, surface: "b"),
            SavedWord(canonicalEntryID: 3, surface: "c"),
        ])
        store.remove(id: 2)
        XCTAssertEqual(store.words.map(\.canonicalEntryID), [1, 3])
    }

    // The bulk remove path is the one that fires under multi-select delete in the Words tab.
    // Production comment: looping over remove(id:) freezes the UI on large deletes.
    func testRemoveByIdsDropsManyInOnePersist() {
        let store = makeStore()
        store.replaceAll(with: (1...5).map { SavedWord(canonicalEntryID: Int64($0), surface: "s\($0)") })
        store.remove(ids: [2, 4])
        XCTAssertEqual(store.words.map(\.canonicalEntryID), [1, 3, 5])
    }

    // remove(ids:) with an empty set is a no-op; the production guard skips persistence so the
    // pre-call array survives unchanged.
    func testRemoveEmptySetIsNoOp() {
        let store = makeStore()
        store.replaceAll(with: [SavedWord(canonicalEntryID: 1, surface: "a")])
        store.remove(ids: [])
        XCTAssertEqual(store.words.map(\.canonicalEntryID), [1])
    }

    // Deleting a source note never deletes saved vocabulary. The note reference is
    // detached while every other card field remains available for study and review.
    func testDetachNoteReferencesPreservesSoleSourceWords() {
        let deletedNoteID = UUID()
        let survivingNoteID = UUID()
        let store = makeStore()
        store.replaceAll(with: [
            SavedWord(canonicalEntryID: 1, surface: "sole", sourceNoteIDs: [deletedNoteID]),
            SavedWord(canonicalEntryID: 2, surface: "shared", sourceNoteIDs: [deletedNoteID, survivingNoteID]),
            SavedWord(canonicalEntryID: 3, surface: "unrelated", sourceNoteIDs: [survivingNoteID]),
        ])

        store.detachNoteReferences(noteIDs: [deletedNoteID])

        XCTAssertEqual(store.words.map(\.canonicalEntryID), [1, 2, 3])
        XCTAssertEqual(store.words[0].sourceNoteIDs, [])
        XCTAssertEqual(store.words[1].sourceNoteIDs, [survivingNoteID])
        XCTAssertEqual(store.words[2].sourceNoteIDs, [survivingNoteID])
    }

    // MARK: - List membership

    // toggleListMembership flips the list ID: adds when absent, removes when present.
    func testToggleListMembershipAddsAndRemoves() {
        let listID = UUID()
        let store = makeStore()
        store.replaceAll(with: [SavedWord(canonicalEntryID: 1, surface: "猫")])
        XCTAssertFalse(store.words[0].wordListIDs.contains(listID))

        store.toggleListMembership(wordID: 1, listID: listID)
        XCTAssertTrue(store.words[0].wordListIDs.contains(listID))

        store.toggleListMembership(wordID: 1, listID: listID)
        XCTAssertFalse(store.words[0].wordListIDs.contains(listID))
    }

    // removeListMembership strips a deleted list from every saved word so no orphan memberships
    // linger after the user deletes a custom list.
    func testRemoveListMembershipStripsFromAllWords() {
        let listA = UUID(), listB = UUID()
        let store = makeStore()
        store.replaceAll(with: [
            SavedWord(canonicalEntryID: 1, surface: "a", wordListIDs: [listA, listB]),
            SavedWord(canonicalEntryID: 2, surface: "b", wordListIDs: [listA]),
            SavedWord(canonicalEntryID: 3, surface: "c", wordListIDs: [listB]),
        ])
        store.removeListMembership(listID: listA)

        XCTAssertFalse(store.words[0].wordListIDs.contains(listA))
        XCTAssertTrue(store.words[0].wordListIDs.contains(listB))
        XCTAssertFalse(store.words[1].wordListIDs.contains(listA))
        XCTAssertTrue(store.words[2].wordListIDs.contains(listB))
    }

    // addToList: only targets words in the supplied id set, skips already-member entries.
    func testAddToListOnlyTargetsSpecifiedWordsAndSkipsExisting() {
        let listID = UUID()
        let store = makeStore()
        store.replaceAll(with: [
            SavedWord(canonicalEntryID: 1, surface: "a", wordListIDs: [listID]),
            SavedWord(canonicalEntryID: 2, surface: "b"),
            SavedWord(canonicalEntryID: 3, surface: "c"),
        ])
        store.addToList(wordIDs: [1, 2], listID: listID)

        XCTAssertEqual(store.words[0].wordListIDs.filter { $0 == listID }.count, 1, "no duplicate when already member")
        XCTAssertTrue(store.words[1].wordListIDs.contains(listID))
        XCTAssertFalse(store.words[2].wordListIDs.contains(listID))
    }

    // removeFromList: only targets words in the supplied id set, skips entries that aren't members.
    func testRemoveFromListOnlyTargetsSpecifiedWordsAndSkipsNonMembers() {
        let listID = UUID()
        let store = makeStore()
        store.replaceAll(with: [
            SavedWord(canonicalEntryID: 1, surface: "a", wordListIDs: [listID]),
            SavedWord(canonicalEntryID: 2, surface: "b", wordListIDs: [listID]),
            SavedWord(canonicalEntryID: 3, surface: "c"),
        ])
        store.removeFromList(wordIDs: [1, 3], listID: listID)

        XCTAssertFalse(store.words[0].wordListIDs.contains(listID))
        XCTAssertTrue(store.words[1].wordListIDs.contains(listID))
        XCTAssertFalse(store.words[2].wordListIDs.contains(listID))
    }

    // MARK: - Personal note

    func testUpdatePersonalNoteSetsAndClears() {
        let store = makeStore()
        store.replaceAll(with: [SavedWord(canonicalEntryID: 1, surface: "猫")])

        store.updatePersonalNote(id: 1, note: "cat in your house")
        XCTAssertEqual(store.words[0].personalNote, "cat in your house")

        store.updatePersonalNote(id: 1, note: nil)
        XCTAssertNil(store.words[0].personalNote)
    }

    // MARK: - Selection

    // setSelection replaces both arrays atomically — UI computes the new state including any
    // mutual-exclusion fold first, then calls this method as the single write.
    func testSetSelectionReplacesBothArraysAtomically() {
        let store = makeStore()
        store.replaceAll(with: [SavedWord(canonicalEntryID: 1, surface: "猫")])

        let glosses = [GlossRef(senseID: 100, glossIndex: 0), GlossRef(senseID: 100, glossIndex: 2)]
        store.setSelection(id: 1, senseIDs: [200, 300], glosses: glosses)

        XCTAssertEqual(store.words[0].selectedSenseIDs, [200, 300])
        XCTAssertEqual(store.words[0].selectedGlosses, glosses)
    }

    // MARK: - Move

    func testMoveReordersEntries() {
        let store = makeStore()
        store.replaceAll(with: [
            SavedWord(canonicalEntryID: 1, surface: "a"),
            SavedWord(canonicalEntryID: 2, surface: "b"),
            SavedWord(canonicalEntryID: 3, surface: "c"),
        ])
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(store.words.map(\.canonicalEntryID), [2, 3, 1])
    }

    // MARK: - reload()

    // reload re-reads from disk. Writer mutates via one store; reader gets the change after reload
    // — simulates the SegmentListView path where an external writer bypasses the published array.
    func testReloadPicksUpExternalWrite() {
        let writer = makeStore()
        let reader = makeReaderStore()
        XCTAssertTrue(reader.words.isEmpty)

        writer.replaceAll(with: [SavedWord(canonicalEntryID: 1, surface: "猫")])
        // reader has stale in-memory state until reload.
        XCTAssertTrue(reader.words.isEmpty)

        // Wait for the writer's off-main persist to land on disk before the reader
        // tries to observe it — without this, reload races past an in-flight write.
        WordsStore.flushPendingWritesForTesting()
        reader.reload()
        XCTAssertEqual(reader.words.map(\.canonicalEntryID), [1])
    }

    // MARK: - toggle (the rich path)

    // First toggle of a previously-unseen card creates it with sourceNoteIDs=[] and
    // encountered={storedSurface} — the "no note context" save path used by the Words tab.
    func testToggleNewCardWithoutNoteIDCreatesCardWithEmptyNoteAttribution() {
        let store = makeStore()
        store.toggle(canonicalEntryID: 1, storedSurface: "食べる")

        XCTAssertEqual(store.words.count, 1)
        XCTAssertEqual(store.words[0].surface, "食べる")
        XCTAssertEqual(store.words[0].encounteredSurfaces, Set(["食べる"]))
        XCTAssertTrue(store.words[0].sourceNoteIDs.isEmpty)
    }

    // First toggle with note context attaches the note. The encountered surface is the
    // user's clicked form, which may differ from the stored (lemma) surface.
    func testToggleNewCardWithNoteIDStoresLemmaAndAttachesNote() {
        let noteID = UUID()
        let store = makeStore()
        store.toggle(
            canonicalEntryID: 1,
            storedSurface: "食べる",
            encounteredSurface: "食べた",
            sourceNoteID: noteID
        )

        XCTAssertEqual(store.words.count, 1)
        XCTAssertEqual(store.words[0].surface, "食べる")
        XCTAssertEqual(store.words[0].encounteredSurfaces, Set(["食べた"]))
        XCTAssertEqual(store.words[0].sourceNoteIDs, [noteID])
    }

    // Toggling on an existing card from a NEW note context adds that note's attribution and
    // adds the encountered surface — even if the surface was already in the set. "wasSavedHere"
    // depends on BOTH the surface AND the note being present, not just the surface.
    func testToggleAddsNoteAttributionWhenSurfaceAlreadyKnownButNoteNew() {
        let noteA = UUID(), noteB = UUID()
        let store = makeStore()
        store.toggle(
            canonicalEntryID: 1,
            storedSurface: "食べる",
            encounteredSurface: "食べる",
            sourceNoteID: noteA
        )

        store.toggle(
            canonicalEntryID: 1,
            storedSurface: "食べる",
            encounteredSurface: "食べる",
            sourceNoteID: noteB
        )

        XCTAssertEqual(Set(store.words[0].sourceNoteIDs), Set([noteA, noteB]))
        XCTAssertEqual(store.words[0].encounteredSurfaces, Set(["食べる"]))
    }

    // Unsaving the only encountered surface from the only attached note removes the whole card.
    func testToggleRemovesCardWhenLastSurfaceAndLastNoteCleared() {
        let noteID = UUID()
        let store = makeStore()
        store.toggle(
            canonicalEntryID: 1,
            storedSurface: "食べる",
            encounteredSurface: "食べる",
            sourceNoteID: noteID
        )
        XCTAssertEqual(store.words.count, 1)

        store.toggle(
            canonicalEntryID: 1,
            storedSurface: "食べる",
            encounteredSurface: "食べる",
            sourceNoteID: noteID
        )

        XCTAssertTrue(store.words.isEmpty)
    }

    // Without a note context, unsaving the last encountered surface removes the card.
    func testToggleRemovesCardWhenLastSurfaceClearedWithoutNoteContext() {
        let store = makeStore()
        store.toggle(canonicalEntryID: 1, storedSurface: "食べる")
        XCTAssertEqual(store.words.count, 1)

        store.toggle(canonicalEntryID: 1, storedSurface: "食べる")
        XCTAssertTrue(store.words.isEmpty)
    }

    // Unsaving one of multiple encountered surfaces keeps the card. The card stays because the
    // other surface keeps it alive — the star on that other surface should still be lit.
    func testToggleKeepsCardWhenOtherEncounteredSurfacesRemain() {
        let noteID = UUID()
        let store = makeStore()
        store.toggle(canonicalEntryID: 1, storedSurface: "食べる", encounteredSurface: "食べた", sourceNoteID: noteID)
        store.toggle(canonicalEntryID: 1, storedSurface: "食べる", encounteredSurface: "食べる", sourceNoteID: noteID)
        XCTAssertEqual(store.words[0].encounteredSurfaces, Set(["食べた", "食べる"]))

        // Unsave 食べる only.
        store.toggle(canonicalEntryID: 1, storedSurface: "食べる", encounteredSurface: "食べる", sourceNoteID: noteID)

        XCTAssertEqual(store.words.count, 1)
        XCTAssertEqual(store.words[0].encounteredSurfaces, Set(["食べた"]))
        XCTAssertEqual(store.words[0].sourceNoteIDs, [noteID], "note attribution persists while another encountered surface remains")
    }

    // Note attribution is dropped when its last encountered surface is removed; the card itself
    // persists because the other note still keeps it alive.
    func testToggleDropsNoteAttributionOnLastSurfaceForThatNote() {
        let noteA = UUID(), noteB = UUID()
        let store = makeStore()
        // Save 食べる from note A.
        store.toggle(canonicalEntryID: 1, storedSurface: "食べる", encounteredSurface: "食べる", sourceNoteID: noteA)
        // Save 食べた from note B (different encountered surface, different note).
        store.toggle(canonicalEntryID: 1, storedSurface: "食べる", encounteredSurface: "食べた", sourceNoteID: noteB)
        XCTAssertEqual(Set(store.words[0].sourceNoteIDs), Set([noteA, noteB]))
        XCTAssertEqual(store.words[0].encounteredSurfaces, Set(["食べる", "食べた"]))

        // Unsave 食べる from note A — both surfaces still present (食べた from B), so card stays.
        // Production behavior: noteA is dropped only when the encountered set becomes empty
        // *after* the removal — which it doesn't here.
        store.toggle(canonicalEntryID: 1, storedSurface: "食べる", encounteredSurface: "食べる", sourceNoteID: noteA)

        XCTAssertEqual(store.words.count, 1)
        XCTAssertEqual(store.words[0].encounteredSurfaces, Set(["食べた"]))
        XCTAssertEqual(Set(store.words[0].sourceNoteIDs), Set([noteA, noteB]),
                       "noteA stays attached because the encountered set still has members from other paths")
    }

    // MARK: - SavedWordStorage.normalizedEntries (the helper that handles duplicates)

    // Two entries with the same canonicalEntryID coalesce to one, preserving first-seen ordering
    // — the documented contract of the helper.
    func testNormalizedEntriesCoalescesDuplicatesAndPreservesOrder() {
        let entries = [
            SavedWord(canonicalEntryID: 3, surface: "c"),
            SavedWord(canonicalEntryID: 1, surface: "a"),
            SavedWord(canonicalEntryID: 3, surface: "c-again"),
            SavedWord(canonicalEntryID: 2, surface: "b"),
        ]
        let normalized = SavedWordStorage.normalizedEntries(entries)
        XCTAssertEqual(normalized.map(\.canonicalEntryID), [3, 1, 2])
    }

    // Merge unions sourceNoteIDs and wordListIDs across the duplicates.
    func testNormalizedEntriesMergesSourceNoteIDsAndWordListIDs() {
        let n1 = UUID(), n2 = UUID()
        let l1 = UUID(), l2 = UUID()
        let entries = [
            SavedWord(canonicalEntryID: 1, surface: "a", sourceNoteIDs: [n1], wordListIDs: [l1]),
            SavedWord(canonicalEntryID: 1, surface: "a", sourceNoteIDs: [n2], wordListIDs: [l2]),
        ]
        let normalized = SavedWordStorage.normalizedEntries(entries)

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(Set(normalized[0].sourceNoteIDs), Set([n1, n2]))
        XCTAssertEqual(Set(normalized[0].wordListIDs), Set([l1, l2]))
    }

    // Regression: when normalizedEntries merges two duplicates, the union of encountered surfaces
    // from both must survive. The previous implementation called the SavedWord initializer
    // without passing encounteredSurfaces, so the init's nil-default reseeded the set to
    // Set([preferredSurface]) and silently lost every other encountered form from both inputs.
    // No production path currently exercises this (replaceAll/toggle callers produce unique
    // canonicalEntryIDs), but the helper's contract is "coalesce duplicates without data loss"
    // and any new caller — CSV import, backup restore from older buggy backups, future bulk add
    // — would hit it.
    func testNormalizedEntriesMergesEncounteredSurfacesFromDuplicates() {
        let entries = [
            SavedWord(canonicalEntryID: 42, surface: "食べる", encounteredSurfaces: ["食べる", "食べた"]),
            SavedWord(canonicalEntryID: 42, surface: "食べる", encounteredSurfaces: ["食べました", "食べない"]),
        ]
        let normalized = SavedWordStorage.normalizedEntries(entries)

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(
            normalized[0].encounteredSurfaces,
            Set(["食べる", "食べた", "食べました", "食べない"]),
            "merge must preserve every encountered surface from both duplicates"
        )
    }

    // Personal note from the first-seen entry wins; falls through to the duplicate only when
    // the existing entry's note is nil.
    func testNormalizedEntriesPreservesFirstSeenPersonalNote() {
        let entries = [
            SavedWord(canonicalEntryID: 1, surface: "a", personalNote: "first"),
            SavedWord(canonicalEntryID: 1, surface: "a", personalNote: "second"),
        ]
        let normalized = SavedWordStorage.normalizedEntries(entries)
        XCTAssertEqual(normalized[0].personalNote, "first")
    }

    func testNormalizedEntriesFallsThroughToDuplicateNoteWhenFirstIsNil() {
        let entries = [
            SavedWord(canonicalEntryID: 1, surface: "a", personalNote: nil),
            SavedWord(canonicalEntryID: 1, surface: "a", personalNote: "second"),
        ]
        let normalized = SavedWordStorage.normalizedEntries(entries)
        XCTAssertEqual(normalized[0].personalNote, "second")
    }

    // Selections: existing wins unless empty, in which case the duplicate's are adopted.
    func testNormalizedEntriesPreservesExistingSelectionsUnlessEmpty() {
        let entries = [
            SavedWord(canonicalEntryID: 1, surface: "a", selectedSenseIDs: [10]),
            SavedWord(canonicalEntryID: 1, surface: "a", selectedSenseIDs: [20]),
        ]
        let normalized = SavedWordStorage.normalizedEntries(entries)
        XCTAssertEqual(normalized[0].selectedSenseIDs, [10])
    }

    func testNormalizedEntriesAdoptsDuplicateSelectionsWhenExistingIsEmpty() {
        let entries = [
            SavedWord(canonicalEntryID: 1, surface: "a", selectedSenseIDs: []),
            SavedWord(canonicalEntryID: 1, surface: "a", selectedSenseIDs: [42]),
        ]
        let normalized = SavedWordStorage.normalizedEntries(entries)
        XCTAssertEqual(normalized[0].selectedSenseIDs, [42])
    }

    // Init runs normalization on load: a corrupted-storage scenario where two duplicate entries
    // somehow ended up in the JSON (e.g., from a prior buggy write or a hand-edited backup)
    // coalesces on next read instead of carrying the duplicate forever.
    func testInitNormalizesDuplicatesOnLoad() throws {
        let duplicates = [
            SavedWord(canonicalEntryID: 1, surface: "a", wordListIDs: [UUID()]),
            SavedWord(canonicalEntryID: 1, surface: "a", wordListIDs: [UUID()]),
        ]
        let data = try JSONEncoder().encode(duplicates)
        defaults.set(data, forKey: Self.storageKey)

        let store = makeStore()

        XCTAssertEqual(store.words.count, 1, "init must dedupe stored duplicates")
        XCTAssertEqual(store.words[0].wordListIDs.count, 2, "merge unions the wordListIDs of the duplicates")
    }

    // MARK: - Re-point

    // Re-pointing swaps the entry id + surface but carries list/note/personal-note metadata over,
    // and folds the old surface into encounteredSurfaces. This is the した→下 → する fix.
    func testRepointChangesEntryAndSurfacePreservingMetadata() {
        let store = makeStore()
        let listID = UUID()
        let noteID = UUID()
        store.add(SavedWord(canonicalEntryID: 100, surface: "下",
                            sourceNoteIDs: [noteID], wordListIDs: [listID],
                            personalNote: "from a song", encounteredSurfaces: ["した"]))

        store.repoint(fromEntryID: 100, toEntryID: 200, lemma: "する")

        XCTAssertNil(store.words.first { $0.canonicalEntryID == 100 }, "old card must be gone")
        let card = store.words.first { $0.canonicalEntryID == 200 }
        XCTAssertEqual(card?.surface, "する")
        XCTAssertEqual(card?.wordListIDs, [listID], "list membership carries over")
        XCTAssertEqual(card?.sourceNoteIDs, [noteID], "source notes carry over")
        XCTAssertEqual(card?.personalNote, "from a song", "personal note carries over")
        XCTAssertEqual(card?.encounteredSurfaces.contains("した"), true)
        XCTAssertEqual(card?.encounteredSurfaces.contains("下"), true, "old surface folds into encountered set")
    }

    // When the target entry is already saved, re-point merges onto it instead of creating a
    // duplicate card (duplicate canonicalEntryID would crash the ForEach identity).
    func testRepointMergesIntoExistingTargetCard() {
        let store = makeStore()
        let listA = UUID()
        let listB = UUID()
        store.add(SavedWord(canonicalEntryID: 100, surface: "下", wordListIDs: [listA]))
        store.add(SavedWord(canonicalEntryID: 200, surface: "する", wordListIDs: [listB]))

        store.repoint(fromEntryID: 100, toEntryID: 200, lemma: "する")

        XCTAssertFalse(store.words.contains { $0.canonicalEntryID == 100 }, "source card removed")
        let targets = store.words.filter { $0.canonicalEntryID == 200 }
        XCTAssertEqual(targets.count, 1, "no duplicate target card")
        XCTAssertEqual(targets.first.map { Set($0.wordListIDs) }, [listA, listB], "list memberships union")
    }

    // Re-pointing to the same id is a no-op (avoids needless churn / self-merge).
    func testRepointToSameEntryIsNoOp() {
        let store = makeStore()
        store.add(SavedWord(canonicalEntryID: 100, surface: "する"))
        store.repoint(fromEntryID: 100, toEntryID: 100, lemma: "する")
        XCTAssertEqual(store.words.count, 1)
        XCTAssertEqual(store.words.first?.canonicalEntryID, 100)
    }
}

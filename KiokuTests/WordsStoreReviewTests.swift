import XCTest
@testable import Kioku

// Characterizes the review side of WordsStore — per-word review counters, the "marked wrong" set,
// lifetime totals, and the SRS scheduling thread-through. These were ReviewStore's tests until
// that type was merged into WordsStore; the behaviour they pin is unchanged, but review state now
// lives on the saved-word row, so every case saves the word it reviews (recording against an
// unsaved entry is a documented no-op).
//
// Each test gets its own UserDefaults suite so cases never collide with .standard or with each
// other when run in parallel.
@MainActor
final class WordsStoreReviewTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var storageKey: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "kioku-review-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storageKey = "kioku.words.test.\(UUID().uuidString)"
        XCTAssertNotNil(defaults, "Failed to construct test UserDefaults suite")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        storageKey = nil
        try await super.tearDown()
    }

    // A store over this test's own suite. `saving` seeds the cards a case reviews — review calls
    // are no-ops on an unsaved entry, so a case that skips this measures nothing.
    private func makeStore(saving ids: [Int64] = []) -> WordsStore {
        let store = WordsStore(userDefaults: defaults, storageKey: storageKey)
        if ids.isEmpty == false {
            store.add(ids.map { SavedWord(canonicalEntryID: $0, surface: "s\($0)") })
        }
        return store
    }

    // A second store over the same storage, for the persistence cases. Flushes first: writes go
    // through a background queue, so a reader built too early sees the previous snapshot.
    private func makeReader() -> WordsStore {
        WordsStore.flushPendingWritesForTesting()
        return WordsStore(userDefaults: defaults, storageKey: storageKey)
    }

    // MARK: - Initialization

    // A fresh suite yields zeroed state in every dimension.
    func testInitFromEmptyStorageIsZeroed() {
        let store = makeStore()
        XCTAssertTrue(store.stats.isEmpty)
        XCTAssertTrue(store.markedWrong.isEmpty)
        XCTAssertEqual(store.lifetimeCorrect, 0)
        XCTAssertEqual(store.lifetimeAgain, 0)
    }

    // MARK: - recordCorrect

    // recordCorrect on a fresh card seeds stats, advances the SRS streak to 1, and bumps
    // the lifetime counter. The card moves off the wrong list (it wasn't there, but the
    // remove is part of the contract).
    func testRecordCorrectSeedsStatsAndAdvancesStreak() {
        let store = makeStore(saving: [1])
        store.recordCorrect(for: 1)

        let st = store.stats[1]
        XCTAssertNotNil(st)
        XCTAssertEqual(st?.correct, 1)
        XCTAssertEqual(st?.again, 0)
        XCTAssertEqual(st?.consecutiveCorrect, 1)
        XCTAssertNotNil(st?.dueDate)
        XCTAssertNotNil(st?.lastReviewedAt)
        XCTAssertEqual(store.lifetimeCorrect, 1)
        XCTAssertTrue(store.markedWrong.isEmpty)
    }

    // Recording against an entry the user never saved changes nothing — the merge made review
    // state a field on the saved word, so there is nowhere to put it.
    func testRecordCorrectOnUnsavedEntryIsANoOp() {
        let store = makeStore()
        store.recordCorrect(for: 1)
        XCTAssertNil(store.stats[1])
        XCTAssertEqual(store.lifetimeCorrect, 0)
    }

    // Subsequent correct answers compound the streak.
    func testRecordCorrectCompoundsStreak() {
        let store = makeStore(saving: [1])
        store.recordCorrect(for: 1)
        store.recordCorrect(for: 1)
        store.recordCorrect(for: 1)

        XCTAssertEqual(store.stats[1]?.correct, 3)
        XCTAssertEqual(store.stats[1]?.consecutiveCorrect, 3)
        XCTAssertEqual(store.lifetimeCorrect, 3)
    }

    // recordCorrect on a card that's currently marked wrong removes it from the wrong set
    // — clearing the "needs a redo" badge after the user gets it right.
    func testRecordCorrectClearsMarkedWrong() {
        let store = makeStore(saving: [1])
        store.recordAgain(for: 1)
        XCTAssertTrue(store.markedWrong.contains(1))

        store.recordCorrect(for: 1)
        XCTAssertFalse(store.markedWrong.contains(1))
    }

    // MARK: - recordAgain

    // recordAgain adds to the wrong set, resets the streak to 0, and bumps lifetimeAgain.
    func testRecordAgainResetsStreakAndAddsToWrongSet() {
        let store = makeStore(saving: [1])
        store.recordCorrect(for: 1) // streak = 1
        store.recordCorrect(for: 1) // streak = 2

        store.recordAgain(for: 1)
        XCTAssertEqual(store.stats[1]?.again, 1)
        XCTAssertEqual(store.stats[1]?.consecutiveCorrect, 0, "streak resets to 0 after an 'again'")
        XCTAssertTrue(store.markedWrong.contains(1))
        XCTAssertEqual(store.lifetimeAgain, 1)
    }

    // recordCorrect after recordAgain restarts the streak at 1, not 0 — i.e., the next
    // correct answer immediately moves the card up the relearn ladder.
    func testRecordCorrectAfterAgainStartsNewStreakAtOne() {
        let store = makeStore(saving: [1])
        store.recordAgain(for: 1)
        store.recordCorrect(for: 1)
        XCTAssertEqual(store.stats[1]?.consecutiveCorrect, 1)
    }

    // MARK: - direction stats

    // recordCorrect with no direction argument (the pre-existing call shape) leaves
    // directionStats untouched — back-compat for callers that don't resolve a direction.
    func testRecordCorrectWithoutDirectionLeavesDirectionStatsEmpty() {
        let store = makeStore(saving: [1])
        store.recordCorrect(for: 1)
        XCTAssertEqual(store.stats[1]?.directionStats, [:])
    }

    // recordCorrect(direction:) seeds that direction's own counters, leaving every other
    // direction untouched.
    func testRecordCorrectWithDirectionSeedsOnlyThatDirection() {
        let store = makeStore(saving: [1])
        store.recordCorrect(for: 1, direction: .kanjiToMeaning)

        let ds = store.stats[1]?.directionStats[QuestionDirection.kanjiToMeaning.rawValue]
        XCTAssertEqual(ds?.correct, 1)
        XCTAssertEqual(ds?.again, 0)
        XCTAssertEqual(ds?.consecutiveCorrect, 1)
        XCTAssertNil(store.stats[1]?.directionStats[QuestionDirection.kanaToMeaning.rawValue])
    }

    // Repeated correct answers in the same direction compound that direction's own streak,
    // independent of a different direction's counters for the same word.
    func testDirectionStreaksAreIndependentPerDirection() {
        let store = makeStore(saving: [1])
        store.recordCorrect(for: 1, direction: .kanjiToMeaning)
        store.recordCorrect(for: 1, direction: .kanjiToMeaning)
        store.recordCorrect(for: 1, direction: .kanaToMeaning)

        XCTAssertEqual(store.stats[1]?.directionStats[QuestionDirection.kanjiToMeaning.rawValue]?.consecutiveCorrect, 2)
        XCTAssertEqual(store.stats[1]?.directionStats[QuestionDirection.kanaToMeaning.rawValue]?.consecutiveCorrect, 1)
    }

    // recordAgain(direction:) resets only that direction's streak and records the miss, leaving
    // other directions' streaks intact.
    func testRecordAgainResetsOnlyThatDirectionsStreak() {
        let store = makeStore(saving: [1])
        store.recordCorrect(for: 1, direction: .kanjiToMeaning)
        store.recordCorrect(for: 1, direction: .kanjiToMeaning)
        store.recordCorrect(for: 1, direction: .kanaToMeaning)

        store.recordAgain(for: 1, direction: .kanjiToMeaning)

        let kanjiToMeaning = store.stats[1]?.directionStats[QuestionDirection.kanjiToMeaning.rawValue]
        XCTAssertEqual(kanjiToMeaning?.again, 1)
        XCTAssertEqual(kanjiToMeaning?.consecutiveCorrect, 0, "streak resets to 0 after an 'again' in that direction")
        XCTAssertEqual(store.stats[1]?.directionStats[QuestionDirection.kanaToMeaning.rawValue]?.consecutiveCorrect, 1)
    }

    // Direction stats persist across store instances alongside the rest of a word's stats.
    func testDirectionStatsSurviveAcrossInstances() {
        let writer = makeStore(saving: [1])
        writer.recordCorrect(for: 1, direction: .meaningToKanji)
        writer.recordAgain(for: 1, direction: .kanaToKanji)

        let reader = makeReader()
        XCTAssertEqual(reader.stats[1]?.directionStats[QuestionDirection.meaningToKanji.rawValue]?.correct, 1)
        XCTAssertEqual(reader.stats[1]?.directionStats[QuestionDirection.kanaToKanji.rawValue]?.again, 1)
    }

    // MARK: - isDue

    // A word with no recorded stats is treated as immediately due — the path that lights
    // up the badge for never-seen flashcards.
    func testIsDueReturnsTrueForUnknownCard() {
        let store = makeStore()
        XCTAssertTrue(store.isDue(id: 42))
    }

    // A correct answer schedules a future due date; the card is not due before that date.
    func testIsDueReturnsFalseBeforeNextScheduledTime() {
        let store = makeStore(saving: [1])
        store.recordCorrect(for: 1)
        XCTAssertFalse(store.isDue(id: 1, at: Date()))
    }

    // After the due date passes, the card is due again.
    func testIsDueReturnsTrueAfterNextScheduledTime() {
        let store = makeStore(saving: [1])
        store.recordCorrect(for: 1)
        let future = Date().addingTimeInterval(60 * 60 * 24 * 365) // 1 year
        XCTAssertTrue(store.isDue(id: 1, at: future))
    }

    // MARK: - dueCount

    // dueCount tallies the words from the supplied list that are currently due.
    func testDueCountSumsOnlyDueWords() {
        let store = makeStore(saving: [1, 2, 3])
        store.recordCorrect(for: 1) // not due
        store.recordAgain(for: 2)   // due in 10 min — not due right now
        // 3 has no stats — counted as due

        XCTAssertEqual(store.dueCount(among: store.words, at: Date()), 1, "only id 3 has no stats and is due now")
    }

    // MARK: - lifetimeAccuracy

    // No reviews recorded yet returns nil — distinguishes "no data" from "0% accuracy".
    func testLifetimeAccuracyNilBeforeAnyReview() {
        XCTAssertNil(makeStore().lifetimeAccuracy)
    }

    // Accuracy is correct / (correct + again) across all reviews.
    func testLifetimeAccuracyComputesCorrectOverTotal() {
        let store = makeStore(saving: [1, 2, 3, 4])
        store.recordCorrect(for: 1)
        store.recordCorrect(for: 2)
        store.recordCorrect(for: 3)
        store.recordAgain(for: 4)
        XCTAssertEqual(store.lifetimeAccuracy ?? 0, 0.75, accuracy: 0.0001)
    }

    // MARK: - applyLegacyReviewBackup (backup restore path)

    // Restoring a backup overwrites the review side of every saved card and persists it. This is
    // the path that replaced ReviewStore.replaceAll: backups still ship review data as a separate
    // payload keyed by entry id, which now has to be folded back onto the word rows.
    func testLegacyBackupRestoreOverwritesReviewStateAndPersists() {
        let writer = makeStore(saving: [10, 20, 30, 999])
        writer.recordCorrect(for: 999) // some prior state

        writer.applyLegacyReviewBackup(
            stats: [
                10: ReviewWordStats(correct: 5, again: 1, consecutiveCorrect: 2),
                20: ReviewWordStats(correct: 0, again: 3),
            ],
            markedWrong: [20, 30],
            learned: [],
            notLearned: [],
            mastered: [],
            lifetimeCorrect: 100,
            lifetimeAgain: 25
        )

        XCTAssertEqual(writer.stats.keys.sorted(), [10, 20])
        XCTAssertEqual(writer.stats[10]?.correct, 5)
        XCTAssertEqual(writer.markedWrong, [20, 30])
        XCTAssertEqual(writer.lifetimeCorrect, 100)
        XCTAssertEqual(writer.lifetimeAgain, 25)

        let reader = makeReader()
        XCTAssertEqual(reader.stats.keys.sorted(), [10, 20])
        XCTAssertEqual(reader.stats[10]?.correct, 5)
        XCTAssertEqual(reader.markedWrong, [20, 30])
        XCTAssertEqual(reader.lifetimeCorrect, 100)
        XCTAssertEqual(reader.lifetimeAgain, 25)
    }

    // MARK: - Persistence

    // Every published field round-trips through a fresh store instance.
    func testStateSurvivesAcrossInstances() {
        let writer = makeStore(saving: [1, 2])
        writer.recordCorrect(for: 1)
        writer.recordCorrect(for: 1)
        writer.recordAgain(for: 2)

        let reader = makeReader()
        XCTAssertEqual(reader.stats[1]?.correct, 2)
        XCTAssertEqual(reader.stats[1]?.consecutiveCorrect, 2)
        XCTAssertEqual(reader.stats[2]?.again, 1)
        XCTAssertTrue(reader.markedWrong.contains(2))
        XCTAssertEqual(reader.lifetimeCorrect, 2)
        XCTAssertEqual(reader.lifetimeAgain, 1)
    }

    // Review stats are written inside the saved-word payload, not in a stats dictionary of their
    // own. Pinning where they live means a future schema change breaks this test and forces a
    // migration plan rather than silently dropping pre-existing review history — the same job the
    // old string-keyed-stats test did before the merge.
    func testReviewStatsArePersistedOnTheSavedWordRow() throws {
        let writer = makeStore(saving: [7])
        writer.recordCorrect(for: 7)
        WordsStore.flushPendingWritesForTesting()

        let raw = defaults.data(forKey: storageKey)
        let decoded = try JSONDecoder().decode([SavedWord].self, from: try XCTUnwrap(raw))
        XCTAssertEqual(decoded.map(\.canonicalEntryID), [7])
        XCTAssertEqual(decoded.first?.reviewStats?.correct, 1)
    }

    // Lifetime totals stay in UserDefaults under their own keys rather than on any one word —
    // they outlive the cards they were earned on, including deleted ones.
    func testLifetimeTotalsPersistIndependentlyOfTheWordRows() {
        let writer = makeStore(saving: [1])
        writer.recordCorrect(for: 1)
        writer.remove(id: 1)

        let reader = makeReader()
        XCTAssertTrue(reader.words.isEmpty)
        XCTAssertEqual(reader.lifetimeCorrect, 1)
    }
}

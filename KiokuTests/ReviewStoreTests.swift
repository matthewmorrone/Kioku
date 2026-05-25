import XCTest
@testable import Kioku

// Characterizes ReviewStore — per-word review counters, the "marked wrong" set, lifetime
// totals, and the SRS scheduling thread-through. Each test gets its own UserDefaults
// suite so cases never collide with .standard or with each other when run in parallel.
@MainActor
final class ReviewStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "kioku-review-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults, "Failed to construct test UserDefaults suite")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeStore() -> ReviewStore {
        ReviewStore(userDefaults: defaults)
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
        let store = makeStore()
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

    // Subsequent correct answers compound the streak.
    func testRecordCorrectCompoundsStreak() {
        let store = makeStore()
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
        let store = makeStore()
        store.recordAgain(for: 1)
        XCTAssertTrue(store.markedWrong.contains(1))

        store.recordCorrect(for: 1)
        XCTAssertFalse(store.markedWrong.contains(1))
    }

    // MARK: - recordAgain

    // recordAgain adds to the wrong set, resets the streak to 0, and bumps lifetimeAgain.
    func testRecordAgainResetsStreakAndAddsToWrongSet() {
        let store = makeStore()
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
        let store = makeStore()
        store.recordAgain(for: 1)
        store.recordCorrect(for: 1)
        XCTAssertEqual(store.stats[1]?.consecutiveCorrect, 1)
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
        let store = makeStore()
        store.recordCorrect(for: 1)
        XCTAssertFalse(store.isDue(id: 1, at: Date()))
    }

    // After the due date passes, the card is due again.
    func testIsDueReturnsTrueAfterNextScheduledTime() {
        let store = makeStore()
        store.recordCorrect(for: 1)
        let future = Date().addingTimeInterval(60 * 60 * 24 * 365) // 1 year
        XCTAssertTrue(store.isDue(id: 1, at: future))
    }

    // MARK: - dueCount

    // dueCount tallies the words from the supplied list that are currently due.
    func testDueCountSumsOnlyDueWords() {
        let store = makeStore()
        store.recordCorrect(for: 1) // not due
        store.recordAgain(for: 2)   // due in 10 min — not due right now
        // 3 has no stats — counted as due
        let words = [1, 2, 3].map { SavedWord(canonicalEntryID: Int64($0), surface: "s\($0)") }

        XCTAssertEqual(store.dueCount(among: words, at: Date()), 1, "only id 3 has no stats and is due now")
    }

    // MARK: - lifetimeAccuracy

    // No reviews recorded yet returns nil — distinguishes "no data" from "0% accuracy".
    func testLifetimeAccuracyNilBeforeAnyReview() {
        XCTAssertNil(makeStore().lifetimeAccuracy)
    }

    // Accuracy is correct / (correct + again) across all reviews.
    func testLifetimeAccuracyComputesCorrectOverTotal() {
        let store = makeStore()
        store.recordCorrect(for: 1)
        store.recordCorrect(for: 2)
        store.recordCorrect(for: 3)
        store.recordAgain(for: 4)
        XCTAssertEqual(store.lifetimeAccuracy ?? 0, 0.75, accuracy: 0.0001)
    }

    // MARK: - replaceAll (backup restore path)

    // replaceAll overwrites every published field and persists the new snapshot.
    func testReplaceAllOverridesEveryFieldAndPersists() {
        let writer = makeStore()
        writer.recordCorrect(for: 999) // some prior state

        let snapshot: [Int64: ReviewWordStats] = [
            10: ReviewWordStats(correct: 5, again: 1, consecutiveCorrect: 2),
            20: ReviewWordStats(correct: 0, again: 3),
        ]
        writer.replaceAll(stats: snapshot, markedWrong: [20, 30], lifetimeCorrect: 100, lifetimeAgain: 25)

        XCTAssertEqual(writer.stats.keys.sorted(), [10, 20])
        XCTAssertEqual(writer.stats[10]?.correct, 5)
        XCTAssertEqual(writer.markedWrong, [20, 30])
        XCTAssertEqual(writer.lifetimeCorrect, 100)
        XCTAssertEqual(writer.lifetimeAgain, 25)

        let reader = makeStore()
        XCTAssertEqual(reader.stats.keys.sorted(), [10, 20])
        XCTAssertEqual(reader.stats[10]?.correct, 5)
        XCTAssertEqual(reader.markedWrong, [20, 30])
        XCTAssertEqual(reader.lifetimeCorrect, 100)
        XCTAssertEqual(reader.lifetimeAgain, 25)
    }

    // MARK: - Persistence

    // Every published field round-trips through a fresh store instance.
    func testStateSurvivesAcrossInstances() {
        let writer = makeStore()
        writer.recordCorrect(for: 1)
        writer.recordCorrect(for: 1)
        writer.recordAgain(for: 2)

        let reader = makeStore()
        XCTAssertEqual(reader.stats[1]?.correct, 2)
        XCTAssertEqual(reader.stats[1]?.consecutiveCorrect, 2)
        XCTAssertEqual(reader.stats[2]?.again, 1)
        XCTAssertTrue(reader.markedWrong.contains(2))
        XCTAssertEqual(reader.lifetimeCorrect, 2)
        XCTAssertEqual(reader.lifetimeAgain, 1)
    }

    // The stats dictionary is JSON-encoded with String keys (JSON keys must be strings).
    // Pinning the on-disk format means a future Int64-keyed schema change breaks this test
    // and forces a migration plan rather than silently dropping pre-existing review history.
    func testStatsAreEncodedWithStringKeys() throws {
        let writer = makeStore()
        writer.recordCorrect(for: 7)

        let raw = defaults.data(forKey: "kioku.review.stats.v1")
        let decoded = try JSONDecoder().decode([String: ReviewWordStats].self, from: try XCTUnwrap(raw))
        XCTAssertEqual(decoded.keys.sorted(), ["7"])
    }
}

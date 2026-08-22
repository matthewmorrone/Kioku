import XCTest
@testable import Kioku

// Verifies WordsStore's canonical mastery-stage derivation: New (untouched), Learning
// (engaged but below the learned bar), Learned (marked/auto-promoted), Mastered (every
// direction, recognition + production, cleared), plus the disjoint due-for-review overlay.
@MainActor
final class WordsStoreMasteryTests: XCTestCase {
    private var suiteName: String = ""
    private var defaults: UserDefaults!
    private var storageKey: String = ""

    // Scopes each test to a throwaway UserDefaults suite so persistence never collides with .standard.
    override func setUp() {
        super.setUp()
        suiteName = "kioku-mastery-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        storageKey = "kioku.words.test.\(UUID().uuidString)"
    }

    // Tears down the per-suite store so no state leaks between tests.
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // A store over this test's own suite, with the cards a case marks or reviews already saved:
    // since the ReviewStore merge, mastery and review state are fields on the saved-word row, so
    // an unsaved entry has nothing to record against.
    private func makeStore(saving ids: [Int64] = []) -> WordsStore {
        let store = WordsStore(userDefaults: defaults, storageKey: storageKey)
        if ids.isEmpty == false {
            store.add(ids.map { SavedWord(canonicalEntryID: $0, surface: "s\($0)") })
        }
        return store
    }

    // A never-reviewed, unmarked word is New.
    func testNewWhenUntouched() {
        let store = makeStore(saving: [1])
        XCTAssertEqual(store.masteryStage(for: 1), .new)
    }

    // A reviewed-but-not-yet-learned word is Learning (auto-learn is off by default so a
    // single correct answer does not promote it).
    func testLearningAfterReview() {
        let store = makeStore(saving: [1])
        store.recordCorrect(for: 1)
        XCTAssertEqual(store.masteryStage(for: 1), .learning)
    }

    // Manually marking "not learned" with no review history still counts as engagement → Learning.
    func testLearningWhenManuallyNotLearned() {
        let store = makeStore(saving: [1])
        store.setLearnedState(.notLearned, for: 1)
        XCTAssertEqual(store.masteryStage(for: 1), .learning)
    }

    // An explicitly-learned word is Learned.
    func testLearnedWhenMarked() {
        let store = makeStore(saving: [1])
        store.setLearnedState(.learned, for: 1)
        XCTAssertEqual(store.masteryStage(for: 1), .learned)
    }

    // A word in the mastered set is Mastered — the stage above Learned, reached via
    // `AutoLearnPolicy.shouldMarkMastered` (exercised end-to-end via the legacy-backup restore here,
    // mirroring how a restored backup seeds the set).
    func testMasteredWhenInMasteredSet() {
        let store = makeStore(saving: [1])
        store.applyLegacyReviewBackup(
            stats: [:], markedWrong: [], learned: [], notLearned: [], mastered: [1],
            lifetimeCorrect: 0, lifetimeAgain: 0
        )
        XCTAssertEqual(store.masteryStage(for: 1), .mastered)
    }

    // Mastered wins over an explicit Learned mark — it's the stricter, higher stage.
    func testMasteredWinsOverLearned() {
        let store = makeStore(saving: [1])
        store.applyLegacyReviewBackup(
            stats: [:], markedWrong: [], learned: [1], notLearned: [], mastered: [1],
            lifetimeCorrect: 0, lifetimeAgain: 0
        )
        XCTAssertEqual(store.masteryStage(for: 1), .mastered)
    }

    // A never-reviewed word is NOT due-for-review (unlike isDue, which treats it as due). This is
    // what keeps New and Due disjoint on the coverage screen.
    func testNotDueForReviewWhenNeverReviewed() {
        let store = makeStore(saving: [1])
        XCTAssertFalse(store.isDueForReview(id: 1, at: .distantFuture))
    }

    // A reviewed word becomes due-for-review once its scheduled dueDate has passed.
    func testDueForReviewWhenReviewedAndLapsed() {
        let store = makeStore(saving: [1])
        store.recordCorrect(for: 1) // schedules dueDate = now + interval
        XCTAssertTrue(store.isDueForReview(id: 1, at: .distantFuture))
        XCTAssertFalse(store.isDueForReview(id: 1, at: .distantPast))
    }
}

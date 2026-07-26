import XCTest
@testable import Kioku

// Verifies ReviewStore's canonical mastery-stage derivation: New (untouched), Learning
// (engaged but below the learned bar), Learned (marked/auto-promoted), Mastered (every
// direction, recognition + production, cleared), plus the disjoint due-for-review overlay.
@MainActor
final class ReviewStoreMasteryTests: XCTestCase {
    private var suiteName: String = ""
    private var defaults: UserDefaults!

    // Scopes each test to a throwaway UserDefaults suite so persistence never collides with .standard.
    override func setUp() {
        super.setUp()
        suiteName = "kioku-mastery-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    // Tears down the per-suite store so no state leaks between tests.
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // A never-reviewed, unmarked word is New.
    func testNewWhenUntouched() {
        let store = ReviewStore(userDefaults: defaults)
        XCTAssertEqual(store.masteryStage(for: 1), .new)
    }

    // A reviewed-but-not-yet-learned word is Learning (auto-learn is off by default so a
    // single correct answer does not promote it).
    func testLearningAfterReview() {
        let store = ReviewStore(userDefaults: defaults)
        store.recordCorrect(for: 1)
        XCTAssertEqual(store.masteryStage(for: 1), .learning)
    }

    // Manually marking "not learned" with no review history still counts as engagement → Learning.
    func testLearningWhenManuallyNotLearned() {
        let store = ReviewStore(userDefaults: defaults)
        store.setLearnedState(.notLearned, for: 1)
        XCTAssertEqual(store.masteryStage(for: 1), .learning)
    }

    // An explicitly-learned word is Learned.
    func testLearnedWhenMarked() {
        let store = ReviewStore(userDefaults: defaults)
        store.setLearnedState(.learned, for: 1)
        XCTAssertEqual(store.masteryStage(for: 1), .learned)
    }

    // A word in the mastered set is Mastered — the stage above Learned, reached via
    // `AutoLearnPolicy.shouldMarkMastered` (exercised end-to-end via `replaceAll` here, mirroring
    // how a restored backup seeds the set).
    func testMasteredWhenInMasteredSet() {
        let store = ReviewStore(userDefaults: defaults)
        store.replaceAll(stats: [:], markedWrong: [], lifetimeCorrect: 0, lifetimeAgain: 0, mastered: [1])
        XCTAssertEqual(store.masteryStage(for: 1), .mastered)
    }

    // Mastered wins over an explicit Learned mark — it's the stricter, higher stage.
    func testMasteredWinsOverLearned() {
        let store = ReviewStore(userDefaults: defaults)
        store.replaceAll(stats: [:], markedWrong: [], lifetimeCorrect: 0, lifetimeAgain: 0, learned: [1], mastered: [1])
        XCTAssertEqual(store.masteryStage(for: 1), .mastered)
    }

    // A never-reviewed word is NOT due-for-review (unlike isDue, which treats it as due). This is
    // what keeps New and Due disjoint on the coverage screen.
    func testNotDueForReviewWhenNeverReviewed() {
        let store = ReviewStore(userDefaults: defaults)
        XCTAssertFalse(store.isDueForReview(id: 1, at: .distantFuture))
    }

    // A reviewed word becomes due-for-review once its scheduled dueDate has passed.
    func testDueForReviewWhenReviewedAndLapsed() {
        let store = ReviewStore(userDefaults: defaults)
        store.recordCorrect(for: 1) // schedules dueDate = now + interval
        XCTAssertTrue(store.isDueForReview(id: 1, at: .distantFuture))
        XCTAssertFalse(store.isDueForReview(id: 1, at: .distantPast))
    }
}

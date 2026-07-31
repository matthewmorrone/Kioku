import XCTest
@testable import Kioku

// Characterizes AutoLearnPolicy: the per-rule bar check (clearsBar) and the two direction-gated
// entry points — shouldMarkLearned, which requires only the 3 recognition (tier1) directions to
// individually clear the bar, and shouldMarkMastered, the stricter sibling requiring all 6
// (tier1 + tier2) directions to clear it.
final class AutoLearnPolicyTests: XCTestCase {

    private func config(
        enabled: Bool = true,
        rule: AutoLearnRule = .accuracyAndMinReviews,
        threshold: Double = 0.9,
        minReviews: Int = 3,
        streak: Int = 5
    ) -> LearnedSettings.Config {
        LearnedSettings.Config(enabled: enabled, rule: rule, threshold: threshold, minReviews: minReviews, streak: streak)
    }

    // Builds a directionStats dictionary where every one of the 6 directions has identical counters.
    private func uniformDirectionStats(correct: Int, again: Int, consecutiveCorrect: Int) -> [String: DirectionStats] {
        var result: [String: DirectionStats] = [:]
        for direction in QuestionDirection.allCases {
            result[direction.rawValue] = DirectionStats(correct: correct, again: again, consecutiveCorrect: consecutiveCorrect)
        }
        return result
    }

    // Builds a directionStats dictionary covering only the given directions.
    private func directionStats(for directions: [QuestionDirection], correct: Int, again: Int, consecutiveCorrect: Int) -> [String: DirectionStats] {
        var result: [String: DirectionStats] = [:]
        for direction in directions {
            result[direction.rawValue] = DirectionStats(correct: correct, again: again, consecutiveCorrect: consecutiveCorrect)
        }
        return result
    }

    // MARK: - clearsBar

    func testClearsBarAccuracyOnlyRequiresAtLeastOneReview() {
        let cfg = config(rule: .accuracyOnly, threshold: 0.9)
        XCTAssertFalse(AutoLearnPolicy.clearsBar(correct: 0, again: 0, consecutiveCorrect: 0, config: cfg))
        XCTAssertTrue(AutoLearnPolicy.clearsBar(correct: 1, again: 0, consecutiveCorrect: 1, config: cfg))
    }

    func testClearsBarAccuracyAndMinReviewsRequiresBothGates() {
        let cfg = config(rule: .accuracyAndMinReviews, threshold: 0.9, minReviews: 3)
        // Enough attempts but accuracy below threshold.
        XCTAssertFalse(AutoLearnPolicy.clearsBar(correct: 2, again: 1, consecutiveCorrect: 0, config: cfg))
        // Accuracy at threshold but not enough attempts.
        XCTAssertFalse(AutoLearnPolicy.clearsBar(correct: 1, again: 0, consecutiveCorrect: 1, config: cfg))
        // Both gates clear.
        XCTAssertTrue(AutoLearnPolicy.clearsBar(correct: 3, again: 0, consecutiveCorrect: 3, config: cfg))
    }

    func testClearsBarConsecutiveCorrectIgnoresLifetimeRatio() {
        let cfg = config(rule: .consecutiveCorrect, streak: 5)
        // Poor lifetime ratio, but a clean streak since the last miss clears the bar.
        XCTAssertTrue(AutoLearnPolicy.clearsBar(correct: 5, again: 20, consecutiveCorrect: 5, config: cfg))
        XCTAssertFalse(AutoLearnPolicy.clearsBar(correct: 100, again: 0, consecutiveCorrect: 4, config: cfg))
    }

    // MARK: - shouldMarkLearned (tier1 only)

    func testShouldMarkLearnedFalseWhenDisabled() {
        let cfg = config(enabled: false, rule: .consecutiveCorrect, streak: 1)
        let stats = uniformDirectionStats(correct: 10, again: 0, consecutiveCorrect: 10)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, config: cfg))
    }

    // A word that has cleared 2 of the 3 tier1 directions but never even attempted the 3rd does
    // not qualify — the whole point of the per-direction gate.
    func testShouldMarkLearnedFalseWhenOneTier1DirectionUntouched() {
        let cfg = config(rule: .consecutiveCorrect, streak: 1)
        var stats = directionStats(for: QuestionDirection.tier1, correct: 5, again: 0, consecutiveCorrect: 5)
        stats.removeValue(forKey: QuestionDirection.kanjiToKana.rawValue)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, config: cfg))
    }

    // Clearing every tier1 (recognition) direction is sufficient for Learned — tier2 (production)
    // evidence isn't required, and can even be entirely absent.
    func testShouldMarkLearnedTrueWhenAllTier1DirectionsClear() {
        let cfg = config(rule: .consecutiveCorrect, streak: 1)
        let stats = directionStats(for: QuestionDirection.tier1, correct: 5, again: 0, consecutiveCorrect: 5)
        XCTAssertTrue(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, config: cfg))
    }

    // Only once all 3 tier1 directions individually clear the configured bar does the word qualify.
    func testShouldMarkLearnedTrueWhenAllSixDirectionsClear() {
        let cfg = config(rule: .consecutiveCorrect, streak: 3)
        let stats = uniformDirectionStats(correct: 3, again: 0, consecutiveCorrect: 3)
        XCTAssertTrue(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, config: cfg))
    }

    // A weak tier1 direction among otherwise-strong ones still blocks graduation to Learned.
    func testShouldMarkLearnedFalseWhenOneTier1DirectionBelowBar() {
        let cfg = config(rule: .consecutiveCorrect, streak: 3)
        var stats = uniformDirectionStats(correct: 3, again: 0, consecutiveCorrect: 3)
        stats[QuestionDirection.kanjiToMeaning.rawValue] = DirectionStats(correct: 1, again: 2, consecutiveCorrect: 0)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, config: cfg))
    }

    // A weak tier2 direction doesn't block Learned at all — tier2 isn't part of this gate.
    func testShouldMarkLearnedTrueEvenWhenTier2DirectionBelowBar() {
        let cfg = config(rule: .consecutiveCorrect, streak: 3)
        var stats = uniformDirectionStats(correct: 3, again: 0, consecutiveCorrect: 3)
        stats[QuestionDirection.meaningToKana.rawValue] = DirectionStats(correct: 1, again: 2, consecutiveCorrect: 0)
        XCTAssertTrue(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, config: cfg))
    }

    // MARK: - shouldMarkMastered (all 6 directions)

    func testShouldMarkMasteredFalseWhenDisabled() {
        let cfg = config(enabled: false, rule: .consecutiveCorrect, streak: 1)
        let stats = uniformDirectionStats(correct: 10, again: 0, consecutiveCorrect: 10)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkMastered(directionStats: stats, config: cfg))
    }

    // A word that has cleared every tier1 direction but not yet any tier2 direction does not
    // qualify for Mastered — recognition alone isn't mastery.
    func testShouldMarkMasteredFalseWhenOnlyTier1Cleared() {
        let cfg = config(rule: .consecutiveCorrect, streak: 1)
        let stats = directionStats(for: QuestionDirection.tier1, correct: 5, again: 0, consecutiveCorrect: 5)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkMastered(directionStats: stats, config: cfg))
    }

    // Only once all 6 directions individually clear the configured bar does the word qualify
    // for Mastered.
    func testShouldMarkMasteredTrueWhenAllSixDirectionsClear() {
        let cfg = config(rule: .consecutiveCorrect, streak: 3)
        let stats = uniformDirectionStats(correct: 3, again: 0, consecutiveCorrect: 3)
        XCTAssertTrue(AutoLearnPolicy.shouldMarkMastered(directionStats: stats, config: cfg))
    }

    // A weak direction among otherwise-strong ones — even a tier2 one — still blocks Mastered.
    func testShouldMarkMasteredFalseWhenOneDirectionBelowBar() {
        let cfg = config(rule: .consecutiveCorrect, streak: 3)
        var stats = uniformDirectionStats(correct: 3, again: 0, consecutiveCorrect: 3)
        stats[QuestionDirection.meaningToKana.rawValue] = DirectionStats(correct: 1, again: 2, consecutiveCorrect: 0)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkMastered(directionStats: stats, config: cfg))
    }
}

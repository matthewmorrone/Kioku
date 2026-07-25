import XCTest
@testable import Kioku

// Characterizes AutoLearnPolicy: the per-rule bar check (clearsBar) and the direction-gated
// entry point (shouldMarkLearned) that now requires every one of the 6 QuestionDirection cases
// to individually clear the bar, not just an aggregate whole-word streak.
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

    // MARK: - shouldMarkLearned

    func testShouldMarkLearnedFalseWhenDisabled() {
        let cfg = config(enabled: false, rule: .consecutiveCorrect, streak: 1)
        let stats = uniformDirectionStats(correct: 10, again: 0, consecutiveCorrect: 10)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, config: cfg))
    }

    // A word that has cleared 5 of the 6 directions but never even attempted the 6th does not
    // qualify — the whole point of the per-direction gate.
    func testShouldMarkLearnedFalseWhenOneDirectionUntouched() {
        let cfg = config(rule: .consecutiveCorrect, streak: 1)
        var stats = uniformDirectionStats(correct: 5, again: 0, consecutiveCorrect: 5)
        stats.removeValue(forKey: QuestionDirection.kanaToKanji.rawValue)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, config: cfg))
    }

    // A word that has cleared every tier-1 direction but not yet any tier-2 direction does not
    // qualify — recognition alone isn't graduation.
    func testShouldMarkLearnedFalseWhenOnlyTier1Cleared() {
        let cfg = config(rule: .consecutiveCorrect, streak: 1)
        var stats: [String: DirectionStats] = [:]
        for direction in QuestionDirection.tier1 {
            stats[direction.rawValue] = DirectionStats(correct: 5, again: 0, consecutiveCorrect: 5)
        }
        XCTAssertFalse(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, config: cfg))
    }

    // Only once all 6 directions individually clear the configured bar does the word qualify.
    func testShouldMarkLearnedTrueWhenAllSixDirectionsClear() {
        let cfg = config(rule: .consecutiveCorrect, streak: 3)
        let stats = uniformDirectionStats(correct: 3, again: 0, consecutiveCorrect: 3)
        XCTAssertTrue(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, config: cfg))
    }

    // A weak direction among otherwise-strong ones still blocks graduation.
    func testShouldMarkLearnedFalseWhenOneDirectionBelowBar() {
        let cfg = config(rule: .consecutiveCorrect, streak: 3)
        var stats = uniformDirectionStats(correct: 3, again: 0, consecutiveCorrect: 3)
        stats[QuestionDirection.meaningToKana.rawValue] = DirectionStats(correct: 1, again: 2, consecutiveCorrect: 0)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, config: cfg))
    }
}

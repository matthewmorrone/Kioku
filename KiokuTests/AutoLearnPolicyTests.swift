import XCTest
@testable import Kioku

// Characterizes AutoLearnPolicy: a word is Learned once every recognition (tier1) direction has at
// least one correct answer, and Mastered once every direction (tier1 + tier2) does. Accuracy,
// streaks and misses play no part.
final class AutoLearnPolicyTests: XCTestCase {

    // Builds a directionStats dictionary covering only the given directions.
    private func directionStats(
        for directions: [QuestionDirection],
        correct: Int,
        again: Int = 0
    ) -> [String: DirectionStats] {
        var result: [String: DirectionStats] = [:]
        for direction in directions {
            result[direction.rawValue] = DirectionStats(correct: correct, again: again, consecutiveCorrect: correct > 0 ? 1 : 0)
        }
        return result
    }

    // MARK: - shouldMarkLearned (tier1 only)

    func testShouldMarkLearnedFalseWhenDisabled() {
        let stats = directionStats(for: QuestionDirection.allCases, correct: 10)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, enabled: false))
    }

    // One right answer in each recognition direction is enough — tier2 can be entirely absent.
    func testShouldMarkLearnedTrueWithOneCorrectPerTier1Direction() {
        let stats = directionStats(for: QuestionDirection.tier1, correct: 1)
        XCTAssertTrue(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, enabled: true))
    }

    // Misses don't count against a direction once it has a right answer.
    func testShouldMarkLearnedIgnoresMisses() {
        let stats = directionStats(for: QuestionDirection.tier1, correct: 1, again: 5)
        XCTAssertTrue(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, enabled: true))
    }

    // A recognition direction never answered right blocks Learned, however strong the others are.
    func testShouldMarkLearnedFalseWhenOneTier1DirectionHasNoCorrect() {
        var stats = directionStats(for: QuestionDirection.tier1, correct: 5)
        stats[QuestionDirection.kanjiToKana.rawValue] = DirectionStats(correct: 0, again: 3, consecutiveCorrect: 0)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, enabled: true))
        stats.removeValue(forKey: QuestionDirection.kanjiToKana.rawValue)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, enabled: true))
    }

    // MARK: - shouldMarkMastered (all 6 directions)

    func testShouldMarkMasteredFalseWhenDisabled() {
        let stats = directionStats(for: QuestionDirection.allCases, correct: 10)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkMastered(directionStats: stats, enabled: false))
    }

    // Recognition alone isn't mastery.
    func testShouldMarkMasteredFalseWhenOnlyTier1Answered() {
        let stats = directionStats(for: QuestionDirection.tier1, correct: 5)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkMastered(directionStats: stats, enabled: true))
    }

    func testShouldMarkMasteredTrueWithOneCorrectPerDirection() {
        let stats = directionStats(for: QuestionDirection.allCases, correct: 1)
        XCTAssertTrue(AutoLearnPolicy.shouldMarkMastered(directionStats: stats, enabled: true))
    }

    // MARK: - kana-only words (hasKanjiForm: false)

    // A kana-only word can never be asked any kanji direction, so its recognition bar is
    // かな→English alone. Held to the full tier1 it would be stuck below Learned forever.
    func testShouldMarkLearnedIgnoresKanjiDirectionsForKanaOnlyWord() {
        let stats = directionStats(for: [.kanaToMeaning], correct: 1)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, hasKanjiForm: true, enabled: true))
        XCTAssertTrue(AutoLearnPolicy.shouldMarkLearned(directionStats: stats, hasKanjiForm: false, enabled: true))
    }

    // Mastery for a kana-only word needs both of its askable directions.
    func testShouldMarkMasteredRequiresBothKanaDirectionsForKanaOnlyWord() {
        let recognitionOnly = directionStats(for: [.kanaToMeaning], correct: 1)
        XCTAssertFalse(AutoLearnPolicy.shouldMarkMastered(directionStats: recognitionOnly, hasKanjiForm: false, enabled: true))
        let both = directionStats(for: [.kanaToMeaning, .meaningToKana], correct: 1)
        XCTAssertTrue(AutoLearnPolicy.shouldMarkMastered(directionStats: both, hasKanjiForm: false, enabled: true))
    }
}

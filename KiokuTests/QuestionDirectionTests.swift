import XCTest
@testable import Kioku

// Characterizes QuestionDirection: the StudyField prompt/answer mapping every activity builds its
// questions from, the tier split that defines the Learned and Mastered bars, and the kanji
// applicability rule that keeps a kana-only word from being held to directions it can't be asked.
final class QuestionDirectionTests: XCTestCase {

    // MARK: - init(prompt:answer:)

    func testInitMapsAllSixDistinctFieldPairs() {
        XCTAssertEqual(QuestionDirection(prompt: .kanji, answer: .meaning), .kanjiToMeaning)
        XCTAssertEqual(QuestionDirection(prompt: .kana, answer: .meaning), .kanaToMeaning)
        XCTAssertEqual(QuestionDirection(prompt: .kanji, answer: .kana), .kanjiToKana)
        XCTAssertEqual(QuestionDirection(prompt: .meaning, answer: .kanji), .meaningToKanji)
        XCTAssertEqual(QuestionDirection(prompt: .meaning, answer: .kana), .meaningToKana)
        XCTAssertEqual(QuestionDirection(prompt: .kana, answer: .kanji), .kanaToKanji)
    }

    // Same-field pairs name no direction; the initializer rejects them.
    func testInitReturnsNilForSameFieldPair() {
        XCTAssertNil(QuestionDirection(prompt: .kanji, answer: .kanji))
        XCTAssertNil(QuestionDirection(prompt: .kana, answer: .kana))
        XCTAssertNil(QuestionDirection(prompt: .meaning, answer: .meaning))
    }

    // MARK: - tier membership

    // Tier 1 (recognition) and tier 2 (production) partition all 6 cases with no overlap.
    func testTiersPartitionAllCases() {
        let tier1 = Set(QuestionDirection.tier1)
        let tier2 = Set(QuestionDirection.tier2)
        XCTAssertEqual(tier1.intersection(tier2), [])
        XCTAssertEqual(tier1.union(tier2), Set(QuestionDirection.allCases))
        XCTAssertEqual(tier1.count, 3)
        XCTAssertEqual(tier2.count, 3)
    }

    // MARK: - kanji applicability

    // The four directions with 漢字 on either side are the ones a kana-only word can never be
    // asked, and exactly those are dropped for it.
    func testApplicableDropsKanjiDirectionsForKanaOnlyWords() {
        let all = QuestionDirection.allCases
        XCTAssertEqual(QuestionDirection.applicable(all, hasKanjiForm: true), all)
        XCTAssertEqual(
            QuestionDirection.applicable(all, hasKanjiForm: false),
            [.kanaToMeaning, .meaningToKana]
        )
    }

    // Recognition and production each keep exactly one askable direction for a kana-only word, so
    // both mastery stages stay reachable.
    func testKanaOnlyWordKeepsOneDirectionPerTier() {
        XCTAssertEqual(QuestionDirection.applicable(QuestionDirection.tier1, hasKanjiForm: false), [.kanaToMeaning])
        XCTAssertEqual(QuestionDirection.applicable(QuestionDirection.tier2, hasKanjiForm: false), [.meaningToKana])
    }

    // `requiresKanji` is what drives the filtering above, and holds for either side of the arrow.
    func testRequiresKanjiCoversBothSides() {
        XCTAssertTrue(QuestionDirection.kanjiToMeaning.requiresKanji)
        XCTAssertTrue(QuestionDirection.meaningToKanji.requiresKanji)
        XCTAssertTrue(QuestionDirection.kanjiToKana.requiresKanji)
        XCTAssertTrue(QuestionDirection.kanaToKanji.requiresKanji)
        XCTAssertFalse(QuestionDirection.kanaToMeaning.requiresKanji)
        XCTAssertFalse(QuestionDirection.meaningToKana.requiresKanji)
    }

    // Only the two English-answer directions need gloss-set grading.
    func testAnswerIsMeaningIdentifiesEnglishAnswers() {
        XCTAssertEqual(
            Set(QuestionDirection.allCases.filter(\.answerIsMeaning)),
            [.kanjiToMeaning, .kanaToMeaning]
        )
    }
}

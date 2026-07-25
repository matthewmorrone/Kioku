import XCTest
@testable import Kioku

// Characterizes FillInBlankDirection's resolution and QuestionDirection.fields, the inverse of
// QuestionDirection.init(prompt:answer:) that FillInBlankView uses to turn a direction back into a
// concrete (prompt, answer) field pair.
final class FillInBlankDirectionTests: XCTestCase {

    // MARK: - Fixed (non-mixed) cases resolve to themselves regardless of seed.

    func testFixedCasesResolveToThemselves() {
        XCTAssertEqual(FillInBlankDirection.kanjiToKana.resolved(seed: 1), .kanjiToKana)
        XCTAssertEqual(FillInBlankDirection.kanaToKanji.resolved(seed: 1), .kanaToKanji)
        XCTAssertEqual(FillInBlankDirection.meaningToKanji.resolved(seed: 1), .meaningToKanji)
        XCTAssertEqual(FillInBlankDirection.meaningToKana.resolved(seed: 1), .meaningToKana)
    }

    // MARK: - .mixed

    // .mixed only ever resolves to one of the 4 Japanese-script-answer directions — never
    // kanjiToMeaning/kanaToMeaning, which AnswerScorer can't grade.
    func testMixedNeverResolvesToAnEnglishAnswerDirection() {
        let englishAnswerDirections: Set<QuestionDirection> = [.kanjiToMeaning, .kanaToMeaning]
        for seed in Int64(-20)...20 {
            let resolved = FillInBlankDirection.mixed.resolved(seed: seed)
            XCTAssertFalse(englishAnswerDirections.contains(resolved), "seed \(seed) resolved to \(resolved)")
        }
    }

    // .mixed is deterministic per seed, so a question doesn't change shape between re-renders.
    func testMixedIsDeterministicPerSeed() {
        let first = FillInBlankDirection.mixed.resolved(seed: 42)
        let second = FillInBlankDirection.mixed.resolved(seed: 42)
        XCTAssertEqual(first, second)
    }

    // Negative seeds (a canonicalEntryID can be negative) don't crash the modulo arithmetic.
    func testMixedHandlesNegativeSeeds() {
        _ = FillInBlankDirection.mixed.resolved(seed: -7)
    }

    // MARK: - QuestionDirection.fields (inverse of init(prompt:answer:))

    func testFieldsIsInverseOfInit() {
        for direction in QuestionDirection.allCases {
            let fields = direction.fields
            XCTAssertEqual(QuestionDirection(prompt: fields.prompt, answer: fields.answer), direction)
        }
    }

    func testFieldsForEachDirection() {
        XCTAssertTrue(QuestionDirection.kanjiToMeaning.fields == (.kanji, .meaning))
        XCTAssertTrue(QuestionDirection.kanaToMeaning.fields == (.kana, .meaning))
        XCTAssertTrue(QuestionDirection.kanjiToKana.fields == (.kanji, .kana))
        XCTAssertTrue(QuestionDirection.meaningToKanji.fields == (.meaning, .kanji))
        XCTAssertTrue(QuestionDirection.meaningToKana.fields == (.meaning, .kana))
        XCTAssertTrue(QuestionDirection.kanaToKanji.fields == (.kana, .kanji))
    }
}

import XCTest
@testable import Kioku

// Characterizes QuestionDirection's two entry points: the direct StudyField prompt/answer mapping
// (used by Multiple Choice's `.mixedFields`) and the JP/English axis resolver (used by both study
// modes' `.japaneseToEnglish`/`.englishToJapanese`/`.mixed`).
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

    // Same-field pairs are never produced by StudyField.randomPair; the initializer rejects them.
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

    // MARK: - forJapaneseEnglishAxis

    func testJapaneseToEnglishWithKanjiForm() {
        let dir = QuestionDirection.forJapaneseEnglishAxis(
            resolved: .japaneseToEnglish, form: .kanji, isKanaOnlySurface: false
        )
        XCTAssertEqual(dir, .kanjiToMeaning)
    }

    func testJapaneseToEnglishWithKanaForm() {
        let dir = QuestionDirection.forJapaneseEnglishAxis(
            resolved: .japaneseToEnglish, form: .kana, isKanaOnlySurface: false
        )
        XCTAssertEqual(dir, .kanaToMeaning)
    }

    func testEnglishToJapaneseWithKanjiForm() {
        let dir = QuestionDirection.forJapaneseEnglishAxis(
            resolved: .englishToJapanese, form: .kanji, isKanaOnlySurface: false
        )
        XCTAssertEqual(dir, .meaningToKanji)
    }

    func testEnglishToJapaneseWithKanaForm() {
        let dir = QuestionDirection.forJapaneseEnglishAxis(
            resolved: .englishToJapanese, form: .kana, isKanaOnlySurface: false
        )
        XCTAssertEqual(dir, .meaningToKana)
    }

    // .original defers to the kana-only flag: a kana-only word's "original" form is kana...
    func testOriginalFormWithKanaOnlySurfaceActsAsKana() {
        let dir = QuestionDirection.forJapaneseEnglishAxis(
            resolved: .japaneseToEnglish, form: .original, isKanaOnlySurface: true
        )
        XCTAssertEqual(dir, .kanaToMeaning)
    }

    // ...while a word with kanji present is treated as its kanji form.
    func testOriginalFormWithoutKanaOnlySurfaceActsAsKanji() {
        let dir = QuestionDirection.forJapaneseEnglishAxis(
            resolved: .japaneseToEnglish, form: .original, isKanaOnlySurface: false
        )
        XCTAssertEqual(dir, .kanjiToMeaning)
    }

    // .mixed/.mixedFields must already be resolved to a concrete case before calling; passing
    // either through defensively yields nil rather than a wrong guess.
    func testUnresolvedDirectionsReturnNil() {
        XCTAssertNil(QuestionDirection.forJapaneseEnglishAxis(resolved: .mixed, form: .kanji, isKanaOnlySurface: false))
        XCTAssertNil(QuestionDirection.forJapaneseEnglishAxis(resolved: .mixedFields, form: .kanji, isKanaOnlySurface: false))
    }
}

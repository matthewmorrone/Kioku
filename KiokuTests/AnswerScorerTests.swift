import XCTest
@testable import Kioku

// Characterizes AnswerScorer's rules: exact Japanese spelling (script folding and romaji conversion
// only), English folding with a small-typo tolerance, and rejection of wrong-script or wrong-word answers.
final class AnswerScorerTests: XCTestCase {

    // MARK: - Exact match

    func testExactKanaMatchIsCorrect() {
        let verdict = AnswerScorer.grade(input: "たべもの", expected: "たべもの")
        XCTAssertTrue(verdict.isCorrect)
    }

    func testExactKanjiMatchIsCorrect() {
        let verdict = AnswerScorer.grade(input: "食べ物", expected: "食べ物")
        XCTAssertTrue(verdict.isCorrect)
    }

    // MARK: - Romaji input

    func testRomajiInputConvertsToKanaBeforeComparing() {
        let verdict = AnswerScorer.grade(input: "tabemono", expected: "たべもの")
        XCTAssertTrue(verdict.isCorrect)
        XCTAssertEqual(verdict.normalizedInput, "たべもの")
    }

    // Romaji input can never match a kanji-expected answer — accepting it would defeat the point of
    // a kanji-production question.
    func testRomajiInputDoesNotMatchKanjiExpected() {
        let verdict = AnswerScorer.grade(input: "tabemono", expected: "食べ物")
        XCTAssertFalse(verdict.isCorrect)
    }

    // MARK: - Kana variant folding

    func testKatakanaInputMatchesHiraganaExpected() {
        let verdict = AnswerScorer.grade(input: "タベモノ", expected: "たべもの")
        XCTAssertTrue(verdict.isCorrect)
    }

    // MARK: - Japanese spelling is exact

    // One kana is often the whole difference between two words: びよういん is "beauty salon".
    func testSmallKanaMattersInJapaneseAnswer() {
        let verdict = AnswerScorer.grade(input: "びよういん", expected: "びょういん")
        XCTAssertFalse(verdict.isCorrect)
    }

    // ず for づ is a misspelling when the learner typed kana.
    func testZuForDzuIsIncorrectInTypedKana() {
        let verdict = AnswerScorer.grade(input: "つずく", expected: "つづく")
        XCTAssertFalse(verdict.isCorrect)
    }

    // Hepburn romaji writes づ as "zu", so a romaji answer can't be held to that distinction.
    func testHepburnRomajiZuMatchesDzu() {
        let verdict = AnswerScorer.grade(input: "tsuzuku", expected: "つづく")
        XCTAssertTrue(verdict.isCorrect)
    }

    // A one-kana slip on a long Japanese answer is still wrong.
    func testSingleKanaTypoOnLongJapaneseAnswerIsIncorrect() {
        let verdict = AnswerScorer.grade(input: "たべもみ", expected: "たべもの")
        XCTAssertFalse(verdict.isCorrect)
    }

    func testDifferentKanjiIsIncorrect() {
        let verdict = AnswerScorer.grade(input: "本", expected: "木")
        XCTAssertFalse(verdict.isCorrect)
    }

    // MARK: - English answers

    // English input is compared as English, never converted to kana first.
    func testEnglishAnswerIsNotConvertedToKana() {
        XCTAssertTrue(AnswerScorer.grade(input: "some", expected: "some").isCorrect)
        XCTAssertTrue(AnswerScorer.grade(input: "name", expected: "name").isCorrect)
    }

    // A single typo on a 4+ character English answer still passes.
    func testSingleTypoOnLongEnglishAnswerIsCorrect() {
        let verdict = AnswerScorer.grade(input: "restaurnt", expected: "restaurant")
        XCTAssertTrue(verdict.isCorrect)
    }

    // Short English answers require an exact match: "cat" for "car" is a different word.
    func testShortEnglishAnswerRequiresExactMatch() {
        let verdict = AnswerScorer.grade(input: "cat", expected: "car")
        XCTAssertFalse(verdict.isCorrect)
    }

    func testAnyAcceptedSpellingPasses() {
        let verdict = AnswerScorer.grade(input: "解る", anyOf: ["分かる", "解る", "判る"])
        XCTAssertTrue(verdict.isCorrect)
    }

    func testShortAnswerExactMatchStillPasses() {
        let verdict = AnswerScorer.grade(input: "木", expected: "木")
        XCTAssertTrue(verdict.isCorrect)
    }

    // MARK: - Empty / whitespace input

    func testEmptyInputIsIncorrect() {
        let verdict = AnswerScorer.grade(input: "", expected: "たべもの")
        XCTAssertFalse(verdict.isCorrect)
    }

    func testWhitespaceOnlyInputIsIncorrect() {
        let verdict = AnswerScorer.grade(input: "   ", expected: "たべもの")
        XCTAssertFalse(verdict.isCorrect)
    }

    // Leading/trailing whitespace around a correct answer is trimmed before comparing.
    func testSurroundingWhitespaceIsTrimmed() {
        let verdict = AnswerScorer.grade(input: "  たべもの  ", expected: "たべもの")
        XCTAssertTrue(verdict.isCorrect)
    }

    // MARK: - Wrong word

    func testCompletelyDifferentWordIsIncorrect() {
        let verdict = AnswerScorer.grade(input: "ねこ", expected: "たべもの")
        XCTAssertFalse(verdict.isCorrect)
    }
}

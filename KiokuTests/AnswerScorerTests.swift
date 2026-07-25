import XCTest
@testable import Kioku

// Characterizes AnswerScorer's tolerance rules: exact match, romaji-to-kana conversion, kana variant
// folding, small-typo tolerance scaled by length, and rejection of wrong-script or wrong-word answers.
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

    // MARK: - Typo tolerance

    // A single-character typo on a 4+ character answer still passes.
    func testSingleTypoOnLongAnswerIsCorrect() {
        let verdict = AnswerScorer.grade(input: "たべもみ", expected: "たべもの") // last kana wrong
        XCTAssertTrue(verdict.isCorrect)
    }

    // Two typos on the same answer exceed the tolerance.
    func testTwoTyposOnLongAnswerIsIncorrect() {
        let verdict = AnswerScorer.grade(input: "たびもみ", expected: "たべもの") // two kana wrong
        XCTAssertFalse(verdict.isCorrect)
    }

    // Short answers (under 4 characters) require an exact match — a 1-edit tolerance would accept an
    // entirely different word (木 vs 本 is 1 edit apart but unrelated).
    func testShortAnswerRequiresExactMatch() {
        let verdict = AnswerScorer.grade(input: "本", expected: "木")
        XCTAssertFalse(verdict.isCorrect)
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

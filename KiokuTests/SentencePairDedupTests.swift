import XCTest
@testable import Kioku

// Pins SentencePairDedup behavior. Normalization is intentionally minimal:
// only the punctuation/quote/whitespace differences that the Tatoeba corpus
// actually generates — never anything that could collapse two semantically
// different sentences.
final class SentencePairDedupTests: XCTestCase {

    private func pair(_ ja: String, _ en: String = "x") -> SentencePair {
        SentencePair(japanese: ja, english: en)
    }

    // Same sentence with and without a trailing 。 should collapse to one.
    // First occurrence wins so order-dependent display (shortest first, etc.)
    // doesn't shuffle.
    func testCollapsesTrailingJapanesePeriod() {
        let result = SentencePairDedup.dedupe([
            pair("これは本だ"),
            pair("これは本だ。"),
        ])
        XCTAssertEqual(result.map(\.japanese), ["これは本だ"])
    }

    // English trailing period / question mark shouldn't break dedup either —
    // we hash on Japanese normalization, English is incidental.
    func testCollapsesDespiteDifferentEnglish() {
        let result = SentencePairDedup.dedupe([
            pair("これは本だ", "This is a book."),
            pair("これは本だ", "It's a book."),
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.english, "This is a book.")
    }

    // Wrapping 「」 quotes (common in Tatoeba dialog excerpts) should not
    // create a duplicate of the same underlying sentence.
    func testStripsWrappingJapaneseQuotes() {
        let result = SentencePairDedup.dedupe([
            pair("「これは本だ」"),
            pair("これは本だ"),
        ])
        XCTAssertEqual(result.count, 1)
    }

    // Leading / trailing whitespace from corpus noise shouldn't survive dedup.
    func testTrimsWhitespace() {
        let result = SentencePairDedup.dedupe([
            pair("  これは本だ  "),
            pair("これは本だ"),
        ])
        XCTAssertEqual(result.count, 1)
    }

    // Genuinely different sentences must NOT collapse — even when they share
    // a long prefix. (Regression guard against an over-eager normalization.)
    func testKeepsDifferentSentences() {
        let result = SentencePairDedup.dedupe([
            pair("これは本だ"),
            pair("これは本ではない"),
        ])
        XCTAssertEqual(result.count, 2)
    }

    // Trailing ASCII / fullwidth question and exclamation marks are
    // sentence-final too; collapsing is desirable here.
    func testCollapsesTrailingQuestionAndBang() {
        let result = SentencePairDedup.dedupe([
            pair("元気？"),
            pair("元気"),
            pair("すごい！"),
            pair("すごい"),
        ])
        XCTAssertEqual(Set(result.map(\.japanese)), Set(["元気？", "すごい！"]))
        // First occurrence wins, so the punctuated forms survive.
    }

    // Empty input is empty output; doesn't crash on edge.
    func testEmptyInput() {
        XCTAssertEqual(SentencePairDedup.dedupe([]).count, 0)
    }
}

import XCTest
@testable import Kioku

// Pins MoraPhonemizer — the kana→romaji/mora layer that feeds a phoneme/romaji forced aligner.
// Covers gojūon, yōon, sokuon (incl. っち→tch), long vowel, moraic n, small-vowel loanword combos,
// and katakana folding (the lyric set is katakana-heavy).
final class MoraPhonemizerTests: XCTestCase {
    private func r(_ kana: String) -> String { MoraPhonemizer.romaji(fromKana: kana) }

    func testGojuon() {
        XCTAssertEqual(r("さくら"), "sakura")
        XCTAssertEqual(r("かなしみ"), "kanashimi")   // 悲しみ reading
        XCTAssertEqual(r("わすれない"), "wasurenai") // 忘れない reading
        XCTAssertEqual(r("ほんとう"), "hontou")
    }

    func testYoon() {
        XCTAssertEqual(r("きゃ"), "kya")
        XCTAssertEqual(r("しゃ"), "sha")
        XCTAssertEqual(r("ちゃ"), "cha")
        XCTAssertEqual(r("じゃ"), "ja")
        XCTAssertEqual(r("にゃ"), "nya")
        XCTAssertEqual(r("りょ"), "ryo")
        XCTAssertEqual(r("しゅ"), "shu")
    }

    func testSokuon() {
        XCTAssertEqual(r("きって"), "kitte")
        XCTAssertEqual(r("まっちゃ"), "matcha")   // っ + ちゃ → tcha
        XCTAssertEqual(r("ざっし"), "zasshi")
    }

    func testLongVowelAndMoraicN() {
        XCTAssertEqual(r("ムーン"), "muun")        // katakana + ー
        XCTAssertEqual(r("ラーメン"), "raamen")
        XCTAssertEqual(r("ん"), "n")
    }

    func testKatakanaLoanwords() {
        XCTAssertEqual(r("フラグメント"), "furagumento")
        XCTAssertEqual(r("ファ"), "fa")            // small-vowel combo
        XCTAssertEqual(r("ティ"), "ti")
    }

    func testMoraSegmentationKeepsSourceKana() {
        let morae = MoraPhonemizer.morae(fromKana: "きゃっと")
        XCTAssertEqual(morae.map(\.kana), ["きゃ", "と"])   // っ geminates the next mora, not its own
        XCTAssertEqual(morae.map(\.romaji), ["kya", "tto"])
    }

    func testEmptyAndPassthrough() {
        XCTAssertEqual(r(""), "")
        XCTAssertEqual(r("OK"), "OK")   // non-kana passes through
    }
}

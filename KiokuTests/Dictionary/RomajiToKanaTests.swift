import XCTest
@testable import Kioku

@MainActor
final class RomajiToKanaTests: XCTestCase {

    private func assertConverts(_ input: String,
                                to expected: String,
                                file: StaticString = #file,
                                line: UInt = #line) {
        let result = RomajiToKana.convert(input)
        XCTAssertNotNil(result, "Expected conversion for \"\(input)\"", file: file, line: line)
        XCTAssertEqual(result?.kana, expected, file: file, line: line)
    }

    private func assertNil(_ input: String,
                           file: StaticString = #file,
                           line: UInt = #line) {
        XCTAssertNil(RomajiToKana.convert(input), file: file, line: line)
    }

    // MARK: Vowels and basic syllables

    func test_vowels() {
        assertConverts("aiueo", to: "あいうえお")
    }

    func test_kRow() {
        assertConverts("kakikukeko", to: "かきくけこ")
    }

    func test_sRow_bothSpellings() {
        assertConverts("sashisuseso", to: "さしすせそ")
        assertConverts("sasisuseso", to: "さしすせそ")
    }

    func test_tRow_bothSpellings() {
        assertConverts("tachitsuteto", to: "たちつてと")
        assertConverts("tatituteto", to: "たちつてと")
    }

    func test_hRow() {
        assertConverts("hahihuheho", to: "はひふへほ")
    }

    func test_fRow() {
        assertConverts("fafifufefo", to: "ふぁふぃふふぇふぉ")
    }

    func test_voicedRows() {
        assertConverts("gagigugego", to: "がぎぐげご")
        assertConverts("zajizuzezo", to: "ざじずぜぞ")
        assertConverts("dadidudedo", to: "だぢづでど")
        assertConverts("babibubebo", to: "ばびぶべぼ")
        assertConverts("papipupepo", to: "ぱぴぷぺぽ")
    }

    // MARK: Yōon

    func test_yoon_k() {
        assertConverts("kyakyukyo", to: "きゃきゅきょ")
    }

    func test_yoon_sh_andSy_areEquivalent() {
        assertConverts("shashusho", to: "しゃしゅしょ")
        assertConverts("syasyusyo", to: "しゃしゅしょ")
    }

    func test_yoon_ch_andTy_areEquivalent() {
        assertConverts("chachucho", to: "ちゃちゅちょ")
        assertConverts("tyatyutyo", to: "ちゃちゅちょ")
    }

    func test_yoon_j_variants() {
        assertConverts("jajujo", to: "じゃじゅじょ")
        assertConverts("jyajyujyo", to: "じゃじゅじょ")
        assertConverts("zyazyuzyo", to: "じゃじゅじょ")
    }

    // MARK: Sokuon (small つ)

    func test_sokuon_doubledConsonant() {
        assertConverts("kitte", to: "きって")
        assertConverts("kakko", to: "かっこ")
        assertConverts("zasshi", to: "ざっし")
    }

    func test_sokuon_matcha() {
        assertConverts("matcha", to: "まっちゃ")
    }

    // MARK: ん handling

    func test_nn_becomes_n() {
        assertConverts("konnichiwa", to: "こんにちわ")
    }

    func test_apostrophe_n() {
        assertConverts("kon'nichiwa", to: "こんにちわ")
    }

    func test_n_before_consonant() {
        assertConverts("kanji", to: "かんじ")
        assertConverts("sanma", to: "さんま")
    }

    func test_n_before_y_is_not_consumed() {
        // `n` + `y` should keep n as start of `nya/nyu/nyo`
        assertConverts("nyanko", to: "にゃんこ")
    }

    func test_trailing_n_left_as_ascii() {
        XCTAssertEqual(RomajiToKana.convert("tan")?.kana, "たn")
        XCTAssertEqual(RomajiToKana.convert("kan")?.kana, "かn")
    }

    // MARK: Katakana (uppercase)

    func test_uppercase_basic() {
        assertConverts("KA", to: "カ")
        assertConverts("KAKI", to: "カキ")
    }

    func test_uppercase_long_vowel() {
        assertConverts("TOU", to: "トー")
        assertConverts("KII", to: "キー")
        assertConverts("TAA", to: "ター")
        assertConverts("MOO", to: "モー")
        assertConverts("TOUKYOU", to: "トーキョー")
    }

    func test_lowercase_no_long_vowel_collapse() {
        // Hiragana keeps the literal trailing vowel.
        assertConverts("tou", to: "とう")
        assertConverts("toukyou", to: "とうきょう")
    }

    // MARK: Mixed and rejection

    func test_input_with_kana_returns_nil() {
        assertNil("たべる")
        assertNil("taべる")
    }

    func test_input_with_kanji_returns_nil() {
        assertNil("食べる")
        assertNil("ta食")
    }

    func test_empty_returns_nil() {
        assertNil("")
    }

    func test_pure_unconvertible_returns_nil() {
        assertNil("xyz")
        assertNil("123")
    }

    // Regression: "Hello" used to produce "ヘllお" because `He`→ヘ, `o`→お, and the
    // embedded `ll` fell through as ASCII. Embedded ASCII letters now reject.
    func test_embedded_ascii_letters_return_nil() {
        assertNil("Hello")
        assertNil("hello")
        assertNil("World")     // would have been "ヲrld"
        assertNil("Hellos")    // would have been "ヘllおs"
    }

    // MARK: Pass-through

    func test_digits_pass_through_when_some_conversion() {
        assertConverts("ka1", to: "か1")
    }

    func test_real_word_tabe() {
        assertConverts("tabe", to: "たべ")
    }
}

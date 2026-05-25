import Foundation
import XCTest
@testable import Kioku

// Verifies SongBreakdownParser against fixture markdown that mirrors the prompt's expected
// output shape: header, italic romaji, dash-bullet word entries, **Gist:** marker, optional
// grammar note, and `---` section separators. Covers chorus references (sameAsLine and
// parallelTo) plus vocalization lines that lack romaji/bullets/gist.
@MainActor
final class SongBreakdownParserTests: XCTestCase {

    private func parser() -> SongBreakdownParser {
        SongBreakdownParser()
    }

    // Verifies a single well-formed section parses all four layers.
    func testParsesSingleFullyPopulatedLine() throws {
        let markdown = """
        **Line 1: 君の名前を呼んだ**
        *kimi no namae wo yonda*

        - **君** (kimi) — you, intimate / second-person
        - **名前** (namae) — name
        - **呼んだ** (yonda) — called, past tense of 呼ぶ

        **Gist:** Called your name.
        """

        let lines = try parser().parse(markdown: markdown)
        XCTAssertEqual(lines.count, 1)
        let line = lines[0]
        XCTAssertEqual(line.index, 1)
        XCTAssertEqual(line.original, "君の名前を呼んだ")
        XCTAssertEqual(line.romaji, "kimi no namae wo yonda")
        XCTAssertEqual(line.words.count, 3)
        XCTAssertEqual(line.words[0].surface, "君")
        XCTAssertEqual(line.words[0].sungRomaji, "kimi")
        XCTAssertEqual(line.words[0].definition, "you, intimate / second-person")
        XCTAssertEqual(line.gist, "Called your name.")
        XCTAssertNil(line.reference)
        XCTAssertNil(line.grammarNote)
    }

    // Verifies multi-section input splits on horizontal rules and yields independent lines.
    func testParsesMultipleLinesSeparatedByHorizontalRule() throws {
        let markdown = """
        **Line 1: 君の名前を呼んだ**
        *kimi no namae wo yonda*

        - **呼ぶ** (yobu) — to call

        **Gist:** Called your name.

        ---

        **Line 2: 振り返らない**
        *furikaeranai*

        - **振り返る** (furikaeru) — to look back

        **Gist:** Won't turn around.
        """

        let lines = try parser().parse(markdown: markdown)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].index, 1)
        XCTAssertEqual(lines[1].index, 2)
        XCTAssertEqual(lines[1].original, "振り返らない")
        XCTAssertEqual(lines[1].romaji, "furikaeranai")
    }

    // Verifies a grammar note captured below the gist is associated with the same line.
    func testParsesGrammarNoteAfterGist() throws {
        let markdown = """
        **Line 1: 振り返らない**
        *furikaeranai*

        - **振り返る** (furikaeru) — to look back, turn around

        **Gist:** Won't turn around.

        The literary negative -ない vs the polite -ません; the subject is unwritten.
        """

        let lines = try parser().parse(markdown: markdown)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].grammarNote, "The literary negative -ない vs the polite -ません; the subject is unwritten.")
    }

    // Verifies "= line N" is captured as a sameAsLine reference and bullets stay empty.
    func testParsesSameAsLineReference() throws {
        let markdown = """
        **Line 1: 君の名前を呼んだ**
        *kimi no namae wo yonda*

        - **呼ぶ** (yobu) — to call

        **Gist:** Called your name.

        ---

        **Line 3: 君の名前を呼んだ**

        = line 1
        """

        let lines = try parser().parse(markdown: markdown)
        XCTAssertEqual(lines.count, 2)
        let repeated = lines[1]
        XCTAssertEqual(repeated.index, 3)
        XCTAssertEqual(repeated.reference, .sameAsLine(1))
        XCTAssertTrue(repeated.words.isEmpty)
    }

    // Verifies "Parallel to line N with substitution: X → Y" carries the substitution text.
    func testParsesParallelToLineReferenceWithSubstitution() throws {
        let markdown = """
        **Line 1: 君の名前を呼んだ**
        *kimi no namae wo yonda*

        - **名前** (namae) — name

        **Gist:** Called your name.

        ---

        **Line 4: たまには君の声を聴かせて**
        *tama ni wa kimi no koe wo kikasete*

        Parallel to line 1 with substitution: 名前 → 声.

        - **聴かせて** (kikasete) — let me hear

        **Gist:** Let me hear your voice once in a while.
        """

        let lines = try parser().parse(markdown: markdown)
        XCTAssertEqual(lines.count, 2)
        let parallel = lines[1]
        XCTAssertEqual(parallel.reference, .parallelTo(line: 1, substitution: "名前 → 声"))
        XCTAssertEqual(parallel.words.count, 1)
        XCTAssertEqual(parallel.words[0].surface, "聴かせて")
        XCTAssertEqual(parallel.gist, "Let me hear your voice once in a while.")
    }

    // Verifies a vocalization-only section collapses to the grammar note holding the bracket text.
    func testParsesVocalizationLine() throws {
        let markdown = """
        **Line 5: Ah〜**

        [Vocal exclamation]
        """

        let lines = try parser().parse(markdown: markdown)
        XCTAssertEqual(lines.count, 1)
        let line = lines[0]
        XCTAssertEqual(line.original, "Ah〜")
        XCTAssertNil(line.romaji)
        XCTAssertTrue(line.words.isEmpty)
        XCTAssertNil(line.gist)
        XCTAssertEqual(line.grammarNote, "[Vocal exclamation]")
    }

    // Verifies bullet variants (asterisk bullet, en-dash separator) still parse correctly.
    func testTolerantBulletAndDashVariants() throws {
        let markdown = """
        **Line 1: テスト**
        *tesuto*

        * **テスト** (tesuto) – a test (en-dash variant)
        - **試験** (shiken) -- exam (double-hyphen variant)

        **Gist:** A test.
        """

        let lines = try parser().parse(markdown: markdown)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].words.count, 2)
        XCTAssertEqual(lines[0].words[0].definition, "a test (en-dash variant)")
        XCTAssertEqual(lines[0].words[1].definition, "exam (double-hyphen variant)")
    }

    // Verifies a response without any **Line N:** headers throws noLinesParsed instead of
    // returning an empty array, so the UI can surface the raw response for debugging.
    func testThrowsWhenNoLinesParsed() {
        let markdown = """
        I'm sorry, I can't help with that request.
        """

        XCTAssertThrowsError(try parser().parse(markdown: markdown)) { error in
            guard let parseError = error as? SongBreakdownParseError else {
                XCTFail("Expected SongBreakdownParseError, got \(error)")
                return
            }
            switch parseError {
            case .noLinesParsed:
                break
            default:
                XCTFail("Expected .noLinesParsed, got \(parseError)")
            }
        }
    }

    // Verifies a header variant `**Line N:** original` (close-bold after the colon) still parses.
    func testHeaderVariantWithBoldClosingAfterColon() throws {
        let markdown = """
        **Line 1:** 君の名前を呼んだ
        *kimi no namae wo yonda*

        - **呼ぶ** (yobu) — to call

        **Gist:** Called your name.
        """

        let lines = try parser().parse(markdown: markdown)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].original, "君の名前を呼んだ")
    }

    // Verifies the parser preserves furigana-mismatch romaji exactly as written, without
    // attempting to normalize against the surface — the prompt explicitly wants these
    // flagged in the romaji field as sung, not as written.
    func testPreservesFuriganaMismatchInSungRomaji() throws {
        let markdown = """
        **Line 1: 愛人の破片**
        *hito no kakera*

        - **愛人** (hito) — lover; sung as 'hito' though written 愛人
        - **破片** (kakera) — fragment; sung as 'kakera' though written 破片

        **Gist:** Fragments of a lover.
        """

        let lines = try parser().parse(markdown: markdown)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].romaji, "hito no kakera")
        XCTAssertEqual(lines[0].words[0].sungRomaji, "hito")
        XCTAssertEqual(lines[0].words[1].sungRomaji, "kakera")
    }

    // Regression: when the model omits horizontal-rule separators between lines and just
    // stacks `**Line N:**` blocks back-to-back, each header must still start a new
    // SongLine. Before this was fixed, only Line 1 was parsed and every subsequent line
    // leaked into Line 1's grammar-note tail (visible to the user as a giant italic blob).
    func testParsesMultipleLinesWithoutHorizontalRules() throws {
        let markdown = """
        **Line 1: 朽ちた花びらに黄昏の翅が**
        *kuchita hanabira ni tasogare no hane ga*

        **Gist:** Twilight wings on withered petals.

        **Line 2: 冷んやりと流れてゆくビリジアン風ミステリアス**
        *hiyari to nagarete yuku birijian fuu misuteriasu*

        **Gist:** A cool viridian mystery flows.

        **Line 3: もう触れられないあの日の命を**
        *mou furerarenai ano hi no inochi wo*

        **Gist:** The life of that day, no longer touchable.
        """

        let lines = try parser().parse(markdown: markdown)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].index, 1)
        XCTAssertEqual(lines[1].index, 2)
        XCTAssertEqual(lines[2].index, 3)
        XCTAssertEqual(lines[0].original, "朽ちた花びらに黄昏の翅が")
        XCTAssertEqual(lines[1].original, "冷んやりと流れてゆくビリジアン風ミステリアス")
        XCTAssertEqual(lines[2].original, "もう触れられないあの日の命を")
        XCTAssertEqual(lines[0].gist, "Twilight wings on withered petals.")
        XCTAssertEqual(lines[1].gist, "A cool viridian mystery flows.")
        XCTAssertEqual(lines[2].gist, "The life of that day, no longer touchable.")
        // The bug we're guarding against: subsequent line headers leaking into Line 1.
        XCTAssertNil(lines[0].grammarNote)
    }
}


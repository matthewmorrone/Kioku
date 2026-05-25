import XCTest
@testable import Kioku

// Pins down the recovery heuristic for breakdowns produced by the pre-fix parser.
// Those values collapsed every line into line 1: subsequent headers + romaji leaked into
// `line[0].grammarNote`, and every line's bullets accumulated into `line[0].words`.
//
// Recovery must:
//   - Detect the broken shape (1 line, grammar note contains `**Line `).
//   - Re-extract line 2..N from the leaked grammar text (Japanese + optional romaji).
//   - Re-bucket the vocabulary by substring-matching `surface` against each `original`.
//   - Leave correctly-shaped breakdowns untouched.
//   - Be idempotent: a second pass yields the same value.
@MainActor
final class SongBreakdownRecoveryTests: XCTestCase {

    func testLeavesCorrectlyShapedBreakdownUntouched() {
        let line = SongLine(
            index: 1,
            original: "君の名前を呼んだ",
            romaji: "kimi no namae wo yonda",
            words: [SongWord(surface: "呼ぶ", sungRomaji: "yobu", definition: "to call")],
            gist: "Called your name.",
            grammarNote: "Past tense of 呼ぶ.",
            reference: nil
        )
        let original = SongBreakdown(
            noteID: UUID(),
            sourceTextHash: "abc",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: .claude,
            lines: [line]
        )
        let recovered = SongBreakdownRecovery.recoverIfNeeded(original)
        XCTAssertEqual(recovered, original)
    }

    func testRecoversTrailingLinesFromLeakedGrammarNote() {
        // Models the on-disk shape that prompted the fix: a single SongLine whose
        // grammarNote is the run-together `**Line N: <jp>** *<romaji>*` blob.
        let line0 = SongLine(
            index: 1,
            original: "朽ちた花びらに黄昏の翅が",
            romaji: "kuchita hanabira ni tasogare no hane ga",
            words: [],
            gist: "Twilight wings on withered petals.",
            grammarNote: """
            **Line 2: 冷んやりと流れてゆくビリジアン風ミステリアス** \
            *hiyari to nagarete yuku birijian fuu misuteriasu* \
            **Line 3: もう触れられないあの日の命を** \
            *mou furerarenai ano hi no inochi wo*
            """,
            reference: nil
        )
        let broken = SongBreakdown(
            noteID: UUID(),
            sourceTextHash: "x",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: .claude,
            lines: [line0]
        )
        let recovered = SongBreakdownRecovery.recoverIfNeeded(broken)
        XCTAssertEqual(recovered.lines.count, 3)
        XCTAssertEqual(recovered.lines[0].original, "朽ちた花びらに黄昏の翅が")
        XCTAssertNil(recovered.lines[0].grammarNote)
        XCTAssertEqual(recovered.lines[1].index, 2)
        XCTAssertEqual(recovered.lines[1].original, "冷んやりと流れてゆくビリジアン風ミステリアス")
        XCTAssertEqual(recovered.lines[1].romaji, "hiyari to nagarete yuku birijian fuu misuteriasu")
        XCTAssertEqual(recovered.lines[2].index, 3)
        XCTAssertEqual(recovered.lines[2].original, "もう触れられないあの日の命を")
    }

    func testRegroupsWordsByOriginalContainingSurface() {
        // Words from the entire song dumped into line[0].words. After recovery, each word
        // should be assigned to the first line whose `original` contains its surface.
        let line0 = SongLine(
            index: 1,
            original: "朽ちた花びらに黄昏の翅が",
            romaji: "kuchita hanabira ni tasogare no hane ga",
            words: [
                SongWord(surface: "花びら", sungRomaji: "hanabira", definition: "petal"),
                SongWord(surface: "流れる", sungRomaji: "nagareru", definition: "to flow"),
                SongWord(surface: "命", sungRomaji: "inochi", definition: "life")
            ],
            gist: nil,
            grammarNote: """
            **Line 2: 冷んやりと流れてゆくビリジアン風ミステリアス** *hiyari* \
            **Line 3: もう触れられないあの日の命を** *mou*
            """,
            reference: nil
        )
        let broken = SongBreakdown(
            noteID: UUID(),
            sourceTextHash: "x",
            generatedAt: Date(),
            provider: .claude,
            lines: [line0]
        )
        let recovered = SongBreakdownRecovery.recoverIfNeeded(broken)
        XCTAssertEqual(recovered.lines.count, 3)
        XCTAssertEqual(recovered.lines[0].words.map(\.surface), ["花びら"])
        XCTAssertEqual(recovered.lines[1].words.map(\.surface), ["流れる"])
        XCTAssertEqual(recovered.lines[2].words.map(\.surface), ["命"])
    }

    func testFallsBackToLineOneForUnmatchedWords() {
        // A word whose surface doesn't appear in any recovered line stays on line 1 so the
        // user still sees it somewhere; we never drop vocabulary on the floor.
        let line0 = SongLine(
            index: 1,
            original: "朽ちた花びらに黄昏の翅が",
            romaji: nil,
            words: [
                SongWord(surface: "宇宙", sungRomaji: "uchuu", definition: "universe (orphan)"),
                SongWord(surface: "花びら", sungRomaji: "hanabira", definition: "petal")
            ],
            gist: nil,
            grammarNote: "**Line 2: 冷んやり流れる** *hiyari nagareru*",
            reference: nil
        )
        let broken = SongBreakdown(
            noteID: UUID(),
            sourceTextHash: "x",
            generatedAt: Date(),
            provider: .claude,
            lines: [line0]
        )
        let recovered = SongBreakdownRecovery.recoverIfNeeded(broken)
        XCTAssertEqual(recovered.lines[0].words.map(\.surface), ["宇宙", "花びら"])
        XCTAssertTrue(recovered.lines[1].words.isEmpty)
    }

    func testIsIdempotent() {
        // Recovery strips the `**Line ` text from line[0].grammarNote, so a second call
        // sees the well-formed shape and returns it unchanged.
        let line0 = SongLine(
            index: 1,
            original: "朽ちた花びらに黄昏の翅が",
            romaji: nil,
            words: [],
            gist: nil,
            grammarNote: "**Line 2: 冷んやり** *hiyari*",
            reference: nil
        )
        let broken = SongBreakdown(
            noteID: UUID(),
            sourceTextHash: "x",
            generatedAt: Date(),
            provider: .claude,
            lines: [line0]
        )
        let once = SongBreakdownRecovery.recoverIfNeeded(broken)
        let twice = SongBreakdownRecovery.recoverIfNeeded(once)
        XCTAssertEqual(once, twice)
    }
}

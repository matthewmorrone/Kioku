import XCTest
@testable import Kioku

// Characterizes SongListenScript.build's step ordering and text content — the pieces that
// went wrong in the 2026-09-02 narration bugs: the pattern-bank note was silently dropped
// from the script entirely, and "/"-separated alternatives in a gist/definition were left
// for AVSpeechSynthesizer to read as the literal word "slash".
final class SongListenScriptTests: XCTestCase {
    private func line(
        index: Int = 1,
        original: String = "夕凪の時間",
        words: [SongWord] = [],
        gist: String? = nil,
        grammarNote: String? = nil
    ) -> SongLine {
        SongLine(index: index, original: original, romaji: nil, words: words, gist: gist, grammarNote: grammarNote, reference: nil)
    }

    private func breakdown(lines: [SongLine]) -> SongBreakdown {
        SongBreakdown(noteID: UUID(), sourceTextHash: "hash", generatedAt: Date(), provider: .stub, lines: lines)
    }

    // The pattern-bank note used to have no corresponding step at all — SongLineCard displayed
    // it, but listen-along skipped it outright. It should now appear as its own .patternNote
    // speech step, after the line's words.
    func testPatternNoteIsSpokenAsItsOwnStep() {
        let bd = breakdown(lines: [line(grammarNote: "Literary negative 〜ず, seen here as a stem form.")])
        let steps = SongListenScript.build(from: bd)

        guard case .speech(let segment) = steps.last else {
            return XCTFail("expected the last step to be speech, got \(String(describing: steps.last))")
        }
        XCTAssertEqual(segment.kind, .patternNote)
        XCTAssertTrue(segment.text.hasPrefix("Pattern to bank:"), "got: \(segment.text)")
        XCTAssertTrue(segment.text.contains("Literary negative"))
    }

    // A line with no grammar note (the common case) emits no .patternNote step at all.
    func testNoPatternNoteStepWhenGrammarNoteIsNil() {
        let bd = breakdown(lines: [line(grammarNote: nil)])
        let steps = SongListenScript.build(from: bd)
        XCTAssertFalse(steps.contains { if case .speech(let s) = $0 { return s.kind == .patternNote } else { return false } })
    }

    // "spinning/weaving" reads as "spinning slash weaving" through TTS — rewritten to "or" in
    // the spoken script only; SongLineCard's on-screen text is untouched by this function.
    func testSlashSeparatedAlternativesAreSpokenAsOr() {
        let bd = breakdown(lines: [line(
            words: [SongWord(surface: "紡ぐ", sungRomaji: "tsumugu", definition: "to spin/weave a story")],
            gist: "Wind and rain/snow mark the seasons."
        )])
        let steps = SongListenScript.build(from: bd)
        let texts = steps.compactMap { step -> String? in
            if case .speech(let s) = step { return s.text }
            return nil
        }
        XCTAssertTrue(texts.contains("to spin or weave a story"), "got: \(texts)")
        XCTAssertTrue(texts.contains("Wind and rain or snow mark the seasons."), "got: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains("/") })
    }

    // A "/" with whitespace already on both sides isn't the alternatives-list shape the
    // rewrite targets, so it's left alone rather than mangled into "word or word2" spacing.
    func testSlashWithSurroundingWhitespaceIsLeftAlone() {
        let bd = breakdown(lines: [line(gist: "Read left / right in that order.")])
        let steps = SongListenScript.build(from: bd)
        let texts = steps.compactMap { step -> String? in
            if case .speech(let s) = step { return s.text }
            return nil
        }
        XCTAssertTrue(texts.contains("Read left / right in that order."), "got: \(texts)")
    }
}

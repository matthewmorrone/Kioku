import XCTest
@testable import Kioku

// Characterizes SongListenScript.build's step ordering and text content — the pieces that
// went wrong in the 2026-09-02 narration bugs: the pattern-bank note was silently dropped
// from the script entirely, and "/"-separated alternatives in a gist/definition were left
// for AVSpeechSynthesizer to read as the literal word "slash".
@MainActor
final class SongListenScriptTests: XCTestCase {
    private func line(
        index: Int = 1,
        original: String = "夕凪の時間",
        romaji: String? = nil,
        words: [SongWord] = [],
        gist: String? = nil,
        grammarNote: String? = nil
    ) -> SongLine {
        SongLine(index: index, original: original, romaji: romaji, words: words, gist: gist, grammarNote: grammarNote, reference: nil)
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
            if case .speech(let s) = step { return s.spokenText ?? s.text }
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

    // The sentence step's spokenText is the LLM's own romaji, converted to kana — a
    // pronunciation-correct substitute for AVSpeechSynthesizer that isn't derivable from the
    // raw kanji alone. The displayed/matched `text` is untouched.
    func testSentenceSpeaksKanaConvertedFromRomaji() {
        let bd = breakdown(lines: [line(original: "君の名前を呼んだ", romaji: "kimi no namae wo yonda")])
        let steps = SongListenScript.build(from: bd)
        guard case .speech(let sentence) = steps.first else {
            return XCTFail("expected a sentence step, got \(String(describing: steps.first))")
        }
        XCTAssertEqual(sentence.kind, .sentence)
        XCTAssertEqual(sentence.text, "君の名前を呼んだ")
        // Spaces between wāpuro-romaji words pass through RomajiToKana unchanged (nothing in
        // its syllable table matches them), so the converted reading keeps them too.
        XCTAssertEqual(sentence.spokenText, "きみ の なまえ を よんだ")
    }

    // A word bullet's spokenText comes from its own sungRomaji the same way — this is the
    // more common case in practice, since a single word is exactly where a homograph reading
    // is ambiguous (the whole point of the feature).
    func testWordSurfaceSpeaksKanaConvertedFromSungRomaji() {
        let bd = breakdown(lines: [line(words: [
            SongWord(surface: "命", sungRomaji: "inochi", definition: "life"),
        ])])
        let steps = SongListenScript.build(from: bd)
        let wordSurfaceSteps = steps.compactMap { step -> SongListenSegment? in
            if case .speech(let s) = step, s.kind == .wordSurface { return s }
            return nil
        }
        // Once before the definition and once after it.
        XCTAssertEqual(wordSurfaceSteps.count, 2)
        for step in wordSurfaceSteps {
            XCTAssertEqual(step.text, "命")
            XCTAssertEqual(step.spokenText, "いのち")
        }
    }

    // The kinds of a line's word steps, in order, with clips named by what they play.
    private func wordStepKinds(_ steps: [SongListenStep]) -> [String] {
        steps.compactMap { step in
            switch step {
            case .speech(let s) where s.kind == .wordSurface: return "say:\(s.text)"
            case .speech(let s) where s.kind == .wordDefinition: return "def:\(s.text)"
            case .wordClip(_, let surface, _, _): return "clip:\(surface)"
            default: return nil
            }
        }
    }

    // Without alignment each word is: reading, definition, reading again.
    func testWordIsReadThenDefinedThenReadAgain() {
        let bd = breakdown(lines: [line(words: [
            SongWord(surface: "夕凪", sungRomaji: "", definition: "evening calm"),
        ])])
        XCTAssertEqual(wordStepKinds(SongListenScript.build(from: bd)), ["say:夕凪", "def:evening calm", "say:夕凪"])
    }

    // The repeat option repeats what leads the word, not the closing reading.
    func testWordRepeatCountRepeatsTheLeadingUtterance() {
        let bd = breakdown(lines: [line(words: [
            SongWord(surface: "夕凪", sungRomaji: "", definition: "evening calm"),
        ])])
        XCTAssertEqual(
            wordStepKinds(SongListenScript.build(from: bd, wordRepeatCount: 3)),
            ["say:夕凪", "say:夕凪", "say:夕凪", "def:evening calm", "say:夕凪"]
        )
    }

    // With the line's cue aligned, the word leads with the singer's own snippet, cut from its
    // checkpoint onset to the next checkpoint's onset.
    func testAlignedWordLeadsWithItsSungSnippet() {
        let bd = breakdown(lines: [line(original: "夕凪の時間", words: [
            SongWord(surface: "時間", sungRomaji: "", definition: "time"),
        ])])
        let cue = SubtitleCue(index: 1, startMs: 1000, endMs: 3000, text: "夕凪の時間", checkpoints: [
            CueCharTiming(timeMs: 1000, charOffsetInCue: 0, charLength: 2),
            CueCharTiming(timeMs: 1600, charOffsetInCue: 2, charLength: 1),
            CueCharTiming(timeMs: 1900, charOffsetInCue: 3, charLength: 2),
        ])
        let steps = SongListenScript.build(
            from: bd,
            lineRanges: [1: (startMs: 1000, endMs: 2600)],
            lineCues: [1: cue],
            wordRepeatCount: 2
        )
        XCTAssertEqual(wordStepKinds(steps), ["clip:時間", "clip:時間", "def:time", "say:時間"])
        guard let clip = steps.first(where: { if case .wordClip = $0 { return true } else { return false } }),
              case .wordClip(_, _, let startMs, let endMs) = clip else {
            return XCTFail("expected a word clip")
        }
        // Last word of the line: runs from its onset to the line's end.
        XCTAssertEqual(startMs, 1900)
        XCTAssertEqual(endMs, 2600)
    }

    // No romaji available (nil, or the referenced-line fall-through never populated it) —
    // spokenText falls back to nil rather than a bad guess, so the audio service falls back
    // to speaking `text` exactly as before this feature existed.
    func testNoRomajiFallsBackToOriginalTextForSynthesis() {
        let bd = breakdown(lines: [line(original: "夕凪の時間", romaji: nil)])
        let steps = SongListenScript.build(from: bd)
        guard case .speech(let sentence) = steps.first else {
            return XCTFail("expected a sentence step, got \(String(describing: steps.first))")
        }
        XCTAssertEqual(sentence.spokenText, "夕凪の時間")
    }

    // A mixed-language line (prompt rule 9) has no per-run romaji to substitute for just its
    // Japanese portions, so the substitution is skipped entirely rather than corrupting the
    // embedded English — SongListenLanguageRuns already routes each run to the right voice
    // from `text` alone.
    func testMixedLanguageLineSkipsRomajiSubstitution() {
        let bd = breakdown(lines: [line(original: "I said 愛してる to her", romaji: "I said aishiteru to her")])
        let steps = SongListenScript.build(from: bd)
        guard case .speech(let sentence) = steps.first else {
            return XCTFail("expected a sentence step, got \(String(describing: steps.first))")
        }
        XCTAssertEqual(sentence.spokenText, "I said 愛してる to her")
    }
}

import Foundation

// Turns a SongBreakdown into a flat, ordered list of things to play/say: for each line, the
// sung audio clip (when a matched time range is available), then the Japanese original, then
// the English gist, then each word — its sung snippet (or reading), its English definition,
// and its reading again — before moving to the next line. This is the "script" that SongLiveListenController plays
// through live, one step at a time; the language tag on each SongListenSegment is what drives
// the Japanese/English voice switching ("code switching") during synthesis, and the leading
// `.clip` step (when present) is what lets the listener hear the line sung before its
// breakdown explains it.
//
// Mirrors SongLineCard's `.sameAsLine` / `.parallelTo` fall-through: a chorus repeat line
// still speaks its own `original` text (it's literally different/identical lyrics being
// sung), but borrows the referenced line's gist/words when its own are empty, exactly like
// the card falls back for display.
//
// `nonisolated`: a pure function of its inputs, callable without hopping onto the main actor
// — without this, the module's default MainActor isolation would make `build` callable only
// from the main actor.
nonisolated enum SongListenScript {
    // Builds the ordered step list for a full breakdown. Pure function of its inputs so a
    // given breakdown + line-range map always produces the same script (and therefore the
    // same audio). `lineRanges` mirrors the per-line play button's own range lookup
    // (SongLineCueMatcher.computeRanges) — pass an empty map (the default) to render
    // narration-only, e.g. when the note has no audio attachment. `lineCues` (each line's
    // matched cue, SongLineCueMatcher.matchedCues) is what word snippets are cut from;
    // `wordRepeatCount` is how many times each word is heard before its definition.
    static func build(
        from breakdown: SongBreakdown,
        lineRanges: [Int: (startMs: Int, endMs: Int)] = [:],
        lineCues: [Int: SubtitleCue] = [:],
        wordRepeatCount: Int = 1
    ) -> [SongListenStep] {
        var steps: [SongListenStep] = []
        let linesByIndex = Dictionary(uniqueKeysWithValues: breakdown.lines.map { ($0.index, $0) })

        for line in breakdown.lines {
            let original = line.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard original.isEmpty == false else { continue }

            // When the sung clip is available, it already says the line — in the singer's own
            // voice, with correct pronunciation for free. A synthesized reading right after it
            // would just repeat the same words a second time. TTS only speaks the sentence
            // when there's no clip to cover it; SongLiveListenController still highlights the
            // Japanese row during the clip itself (see its synthetic `.sentence`-kind segment
            // for `.clip` steps).
            if let range = lineRanges[line.index] {
                steps.append(.clip(lineIndex: line.index, startMs: range.startMs, endMs: range.endMs))
            } else {
                steps.append(.speech(SongListenSegment(
                    lineIndex: line.index,
                    kind: .sentence,
                    text: original,
                    language: .japanese,
                    spokenText: spokenReading(original: original, romaji: line.romaji)
                )))
            }

            if let gist = effectiveGist(for: line, linesByIndex: linesByIndex), gist.isEmpty == false {
                steps.append(.speech(SongListenSegment(lineIndex: line.index, kind: .translation, text: ttsFriendlyText(gist), language: .english)))
            }

            // Each word: heard `wordRepeatCount` times (the singer's own snippet when the line's
            // alignment brackets it, else the synthesized reading), then its definition, then the
            // synthesized reading once more so the word is the last thing heard before moving on.
            // `searchFrom` walks the cue text forward so a word sung twice maps in order.
            var searchFrom = 0
            for word in effectiveWords(for: line, linesByIndex: linesByIndex) {
                let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                guard surface.isEmpty == false else { continue }
                let spoken = SongListenSegment(
                    lineIndex: line.index,
                    kind: .wordSurface,
                    text: surface,
                    language: .japanese,
                    spokenText: spokenReading(original: surface, romaji: word.sungRomaji)
                )

                var leading = SongListenStep.speech(spoken)
                if let cue = lineCues[line.index], let lineEndMs = lineRanges[line.index]?.endMs,
                   let located = SongWordClipLocator.locate(surface, in: cue, lineEndMs: lineEndMs, searchFrom: searchFrom) {
                    leading = .wordClip(lineIndex: line.index, surface: surface, startMs: located.startMs, endMs: located.endMs)
                    searchFrom = located.nextSearchFrom
                }
                for _ in 0..<max(1, wordRepeatCount) {
                    steps.append(leading)
                }

                let definition = SongLineCard.truncatingAtSemicolon(SongLineCard.stripInlineMarkdown(word.definition))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if definition.isEmpty == false {
                    steps.append(.speech(SongListenSegment(lineIndex: line.index, kind: .wordDefinition, text: ttsFriendlyText(definition), language: .english)))
                }
                steps.append(.speech(spoken))
            }

            // Previously omitted entirely — the pattern-bank note (displayed by
            // SongLineCard.patternNote) never had a corresponding script step, so listen-along
            // silently skipped it no matter how "listenable" its prose was.
            if let pattern = effectivePatternNote(for: line, linesByIndex: linesByIndex), pattern.isEmpty == false {
                let cleaned = SongLineCard.stripInlineMarkdown(SongLineCard.strippingPatternToBankPrefix(pattern))
                if cleaned.isEmpty == false {
                    steps.append(.speech(SongListenSegment(lineIndex: line.index, kind: .patternNote, text: "Pattern to bank: \(ttsFriendlyText(cleaned))", language: .english)))
                }
            }
        }
        return steps
    }

    // Substitutes a pronunciation-correct kana reading for a Japanese kanji/kana string,
    // derived from the LLM's own resolved romaji (SongLine.romaji / SongWord.sungRomaji —
    // already computed for on-screen display, not new data), for AVSpeechSynthesizer to speak
    // instead of `original`. Kanji readings are ambiguous (homographs, proper nouns, poetic
    // readings), so letting the synthesizer guess from raw kanji is unreliable; kana has only
    // one reading, so once the ambiguity is resolved once (by the LLM, same as furigana would)
    // there's nothing left to mispronounce. Feeding the *romaji* itself to the synthesizer
    // isn't an option: SongListenLanguageRuns classifies Latin script as English, so it would
    // route to the English voice and be read as English words, not Japanese — hence the
    // romaji→kana conversion here rather than passing romaji straight through.
    //
    // Falls back to `original` (today's behavior, i.e. a no-op) whenever anything about this
    // isn't safe: no romaji available, `original` has embedded non-Japanese content (a mixed
    // line per prompt rule 9 — SongListenLanguageRuns already splits those into per-language
    // runs against `original`, and there's no per-run romaji to substitute for just the
    // Japanese portions), or RomajiToKana can't cleanly convert the romaji (proper nouns and
    // loanwords routinely contain sounds outside its wāpuro table). This can only ever improve
    // pronunciation or leave it unchanged — never regress it.
    private static func spokenReading(original: String, romaji: String?) -> String {
        guard let romaji, romaji.isEmpty == false else { return original }
        let hasEmbeddedEnglish = SongListenLanguageRuns.split(original, defaultLanguage: .japanese)
            .contains { $0.language == .english }
        guard hasEmbeddedEnglish == false else { return original }
        guard let converted = RomajiToKana.convert(romaji), converted.didConvert else { return original }
        return converted.kana
    }

    // Rewrites a "/"-separated alternative like "spinning/weaving" as "spinning or weaving" —
    // AVSpeechSynthesizer reads a bare "/" as the literal word "slash" (or mangles it
    // depending on context), which never sounds like natural speech. Only a "/" directly
    // between two word characters is rewritten; one with whitespace already on either side is
    // left alone (not the alternatives-list shape this targets). Applied only to text that
    // reaches the narration script — the visually-displayed card keeps "/" as written.
    private static func ttsFriendlyText(_ text: String) -> String {
        text.replacingOccurrences(of: #"(\w)/(\w)"#, with: "$1 or $2", options: .regularExpression)
    }

    // Same "own value, else the referenced line's value" rule as SongLineCard.effectiveGrammarNote.
    private static func effectivePatternNote(for line: SongLine, linesByIndex: [Int: SongLine]) -> String? {
        if let g = line.grammarNote, g.isEmpty == false { return g }
        if let reference = line.reference {
            return referencedLine(for: reference, linesByIndex: linesByIndex)?.grammarNote
        }
        return nil
    }

    // Same "own value, else the referenced line's value" rule as SongLineCard.effectiveGist.
    private static func effectiveGist(for line: SongLine, linesByIndex: [Int: SongLine]) -> String? {
        if let g = line.gist, g.isEmpty == false { return g }
        if let reference = line.reference {
            return referencedLine(for: reference, linesByIndex: linesByIndex)?.gist
        }
        return nil
    }

    // Same fall-through as SongLineCard.effectiveWords, plus the same particle/English
    // exclusion (SongWordFilter) so listen-along narration never says out loud a bullet the
    // on-screen card wouldn't even show.
    private static func effectiveWords(for line: SongLine, linesByIndex: [Int: SongLine]) -> [SongWord] {
        let words: [SongWord]
        if line.words.isEmpty == false {
            words = line.words
        } else if let reference = line.reference {
            words = referencedLine(for: reference, linesByIndex: linesByIndex)?.words ?? []
        } else {
            words = []
        }
        return words.filter(SongWordFilter.isVocabularyWord)
    }

    // Resolves a `.sameAsLine` / `.parallelTo` reference to its target line, if present.
    private static func referencedLine(for reference: LineReference, linesByIndex: [Int: SongLine]) -> SongLine? {
        switch reference {
        case .sameAsLine(let n): return linesByIndex[n]
        case .parallelTo(line: let n, substitution: _): return linesByIndex[n]
        }
    }
}

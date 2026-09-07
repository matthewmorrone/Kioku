import Foundation

// Splits one segment's text into same-language runs so SongListenAudioService can switch
// voices *inside* a segment. An English gist or definition routinely quotes Japanese
// ("contracted form of 愛している", "lit. 'the dusk hour', 黄昏 = 誰そ彼"), and a sung line can
// carry English ("I said 愛してる to her"); handed whole to one voice, the other language's
// characters are skipped or mangled. Runs keep the original order, so the cue for the whole
// segment still covers everything that was said.
//
// Classification is per character: kana/kanji (and Japanese punctuation) → Japanese, Latin
// letters → English, everything else (spaces, ASCII punctuation, digits) is neutral and
// simply stays attached to whichever run it sits in. Neutral text before the first classified
// character is carried into the first run. Text with no classified characters at all is one
// run in `defaultLanguage`.
//
// `nonisolated`: called from the `nonisolated` SongListenAudioService.
nonisolated enum SongListenLanguageRuns {

    // Splits `text` into runs; never returns an empty array for non-empty input.
    //
    // Neutral characters (spaces, ASCII punctuation, digits) are buffered separately from the
    // run being built rather than appended straight into it: which run they belong to isn't
    // known until the NEXT classified character arrives. If that next character continues the
    // same language, the buffered text was internal to the run (e.g. spaces between English
    // words) and merges in. If it starts a different language, the buffered text sits between
    // two runs (e.g. the space and "(" between a Japanese word and a following English aside)
    // and belongs to the run about to START, not the one ending — otherwise trailing
    // punctuation like "(" (not whitespace, so appendRun's trim wouldn't strip it) would stick
    // to the wrong run. `pendingNeutral` losslessly holds this until that decision can be made.
    static func split(_ text: String, defaultLanguage: SongListenLanguage) -> [SongListenSegmentRun] {
        var runs: [SongListenSegmentRun] = []
        var currentText = ""
        var currentLanguage: SongListenLanguage? = nil
        var pendingNeutral = ""

        for character in text {
            guard let language = classify(character) else {
                pendingNeutral.append(character)
                continue
            }
            if let currentLanguage {
                if currentLanguage == language {
                    currentText += pendingNeutral
                } else {
                    appendRun(&runs, text: currentText, language: currentLanguage)
                    currentText = pendingNeutral
                }
            } else {
                currentText = pendingNeutral
            }
            pendingNeutral = ""
            currentLanguage = language
            currentText.append(character)
        }

        if let currentLanguage {
            currentText += pendingNeutral
            appendRun(&runs, text: currentText, language: currentLanguage)
        } else {
            let trailing = currentText + pendingNeutral
            if trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                appendRun(&runs, text: trailing, language: defaultLanguage)
            }
        }
        return runs
    }

    // Trims a run and drops it if nothing speakable is left (e.g. a lone space between two
    // runs of the other language would otherwise become an empty utterance).
    private static func appendRun(_ runs: inout [SongListenSegmentRun], text: String, language: SongListenLanguage) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        runs.append(SongListenSegmentRun(text: trimmed, language: language))
    }

    // Language of one character, or nil for neutral characters that belong to whichever run
    // surrounds them.
    private static func classify(_ character: Character) -> SongListenLanguage? {
        if character.unicodeScalars.contains(where: ScriptClassifier.isJapaneseScalar)
            || ScriptClassifier.isJapanesePunctuation(character) {
            return .japanese
        }
        if character.unicodeScalars.contains(where: isLatinLetter) {
            return .english
        }
        return nil
    }

    // ASCII and Latin-1 letters (so "Lumière" and "Chénon" classify as one English run).
    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
            || (0xC0...0x24F).contains(value)
    }
}

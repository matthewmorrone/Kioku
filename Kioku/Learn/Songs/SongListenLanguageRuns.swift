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
    static func split(_ text: String, defaultLanguage: SongListenLanguage) -> [SongListenSegmentRun] {
        var runs: [SongListenSegmentRun] = []
        var currentText = ""
        var currentLanguage: SongListenLanguage? = nil

        for character in text {
            guard let language = classify(character) else {
                currentText.append(character)
                continue
            }
            if let currentLanguage, currentLanguage != language {
                appendRun(&runs, text: currentText, language: currentLanguage)
                currentText = ""
            }
            currentLanguage = language
            currentText.append(character)
        }

        if let currentLanguage {
            appendRun(&runs, text: currentText, language: currentLanguage)
        } else if currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            appendRun(&runs, text: currentText, language: defaultLanguage)
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

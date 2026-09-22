import Foundation

// Decides which of a line's SongWord bullets are actually worth showing/speaking as
// vocabulary — used by both SongLineCard's on-screen chip list and SongListenScript's
// listen-along narration, so the two surfaces never disagree about what counts.
//
// Excludes two kinds of bullet the LLM occasionally emits despite the breakdown prompt asking
// it not to (SongBreakdownPrompt rules 9 and 24): a pure grammatical particle (は/が/を/…,
// checked against the same canonical KanaData.particleSet the Read-tab vocab extractor uses),
// and a bullet whose surface is English rather than Japanese (a mixed-language line's English
// portion mistakenly given its own word bullet instead of just the Japanese).
//
// The English check is a script test, not a heuristic: ScriptClassifier.containsJapanese
// looks for actual kana/kanji scalars, so a genuine Japanese word — kanji, kana, or a
// katakana loanword — always contains at least one and is never misclassified as English by
// this, even when its definition happens to gloss an English-derived term.
nonisolated enum SongWordFilter {
    // Whether `word` should be shown/spoken as vocabulary — false for a pure particle or a
    // non-Japanese (English) surface.
    static func isVocabularyWord(_ word: SongWord) -> Bool {
        let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard surface.isEmpty == false else { return false }
        guard ScriptClassifier.containsJapanese(surface) else { return false }
        guard KanaData.particleSet.contains(surface) == false else { return false }
        return true
    }
}

import Foundation

// The lookup sheet's guess for an unknown katakana word: the dictionary word it is most likely a
// respelling of (カステイラ → カステラ). Lookup-only; the segmenter never sees these.
extension DictionaryStore {
    // The variant (KatakanaSpellingVariants) the dictionary has, fewest rewrites first and then the
    // most frequent word, with its entry; nil for non-katakana surfaces or when no variant is a word.
    nonisolated func katakanaSpellingGuess(for surface: String) throws -> SpellingSuggestion? {
        guard surface.count >= 2, ScriptClassifier.isPureKatakana(surface) else { return nil }
        var best: (rewrites: Int, rank: Int, suggestion: SpellingSuggestion)?
        for variant in KatakanaSpellingVariants.variants(of: surface) {
            if let best, variant.rewrites > best.rewrites { break }
            guard let entry = try lookupExactKana(surface: variant.spelling).first else { continue }
            let rank = entry.frequencyRank ?? Int.max
            if best == nil || rank < best!.rank {
                best = (variant.rewrites, rank, SpellingSuggestion(entry: entry, spelling: variant.spelling))
            }
        }
        return best?.suggestion
    }
}

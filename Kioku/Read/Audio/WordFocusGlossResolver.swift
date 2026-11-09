import Foundation

// The short meaning shown under a word in the word-by-word view and in the cast lyric video: the
// breakdown's, else the dictionary's, each only where the shared filter lets that word have one
// (the same words that get a bubble on the lyrics card). One implementation for the live view and
// the video, so both show the same meaning.
enum WordFocusGlossResolver {
    // The meaning for `word`, or "" when it has none or its kind is hidden.
    static func gloss(
        for word: WordFocusWord,
        placement: SongBreakdownPlacement?,
        filter: LyricWordMeaningFilter,
        dictionaryGloss: ((Int, String) -> String?)?
    ) -> String {
        guard word.interludeDurationMs == nil else { return "" }
        let wordRange = NSRange(location: word.id, length: (word.surface as NSString).length)
        let placed = placement?.words(overlapping: wordRange) ?? []
        let fromBreakdown = placed.lazy
            .filter { filter.allows(breakdownWord: $0.word) }
            .compactMap { LyricsView.shortGloss($0.word.definition) }.first
        // A word the breakdown covers but whose kind is hidden gets no dictionary meaning either;
        // one whose breakdown meaning is just too long for here falls back to the dictionary's.
        let isHidden = placed.contains { filter.allows(breakdownWord: $0.word) == false }
        let fromDictionary = isHidden == false && filter.allows(dictionaryWord: word.surface, at: word.id)
            ? dictionaryGloss?(word.id, word.surface).flatMap(LyricsView.shortGloss)
            : nil
        return fromBreakdown ?? fromDictionary ?? ""
    }
}

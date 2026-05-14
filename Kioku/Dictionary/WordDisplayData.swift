import Foundation

// Bundles all display data for one dictionary entry so callers make one fetch, not three.
// `nonisolated` so the bundle (and its DictionaryEntry-typed `entry`) can move freely across
// actor boundaries — flashcards and detached fetch tasks rely on this.
nonisolated public struct WordDisplayData: Equatable {
    // The full dictionary entry including senses, kanji forms, and kana forms.
    public let entry: DictionaryEntry
    // Pitch accent records for the entry's primary word+kana pair. Empty when not in DB.
    public let pitchAccents: [PitchAccent]
    // Example sentences from Tatoeba containing the surface. Capped at 20 by the query.
    public let sentences: [SentencePair]

    public init(entry: DictionaryEntry, pitchAccents: [PitchAccent], sentences: [SentencePair]) {
        // Bundles entry metadata, pitch accent records, and example sentences into one displayable unit.
        self.entry = entry
        self.pitchAccents = pitchAccents
        self.sentences = sentences
    }
}

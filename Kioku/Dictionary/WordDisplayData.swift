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
    // Heuristic per-sense routing of `sentences`. Keys are senseIDs; missing senses had no match.
    public let sentencesBySenseID: [Int64: [SentencePair]]
    // Sentences that didn't route confidently to a single sense — shown as a fallback Examples block.
    public let unroutedSentences: [SentencePair]

    public init(entry: DictionaryEntry, pitchAccents: [PitchAccent], sentences: [SentencePair]) {
        // Bundles entry metadata, pitch accent records, and example sentences into one displayable unit.
        // Routes sentences to senses by gloss-word overlap so each sense card can show its own examples.
        self.entry = entry
        self.pitchAccents = pitchAccents
        self.sentences = sentences
        let routing = SentenceSenseRouter.route(sentences: sentences, senses: entry.senses)
        self.sentencesBySenseID = routing.bySense
        self.unroutedSentences = routing.unrouted
    }
}

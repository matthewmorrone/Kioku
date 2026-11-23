import Foundation

// One candidate reading's score in ReadingContextTable.scores, by part, with the counts behind it
// (segcli's `readings` mode prints them). `total` is what choose ranks.
nonisolated struct ReadingScore: Sendable {
    let reading: String
    let count: Int
    let addedCount: Double
    let kanjiTotal: Double
    let candidateCount: Int
    // The frequency prior, or for a kanji with a model only what a web note's added counts shift it by.
    let prior: Double
    // The reading model's log-probability of this reading among the candidates, from the words around
    // the run; zero for a kanji without a model.
    let context: Double
    let apple: Double
    // The vote for a reading that makes the text around the run spell a dictionary expression
    // (PhraseReadingEvidence).
    let phrase: Double
    var total: Double { prior + context + apple + phrase }
}

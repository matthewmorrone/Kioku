import Foundation

// One candidate reading's score in ReadingContextTable.scores, by part, with the counts behind it
// (segcli's `readings` mode dumps them so a scoring change can be tried offline). `total` is what
// choose ranks.
nonisolated struct ReadingScore: Sendable {
    let reading: String
    let count: Int
    let addedCount: Double
    let kanjiTotal: Double
    let candidateCount: Int
    let classCount: Int
    let previousSeen: Int
    let nextSeen: Int
    let prior: Double
    let previous: Double
    let next: Double
    let apple: Double
    var total: Double { prior + previous + next + apple }
}

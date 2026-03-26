import Foundation

// Stores cumulative review results for one word, keyed by canonicalEntryID in ReviewStore.
// Computed properties derive accuracy metrics from the stored counters.
struct ReviewWordStats: Codable, Hashable {
    var correct: Int
    var again: Int
    var lastReviewedAt: Date?

    // Total number of review attempts for this word.
    var total: Int { correct + again }

    // Fraction of reviews answered correctly; nil when the word has not yet been reviewed.
    var accuracy: Double? {
        let t = total
        guard t > 0 else { return nil }
        return Double(correct) / Double(t)
    }
}

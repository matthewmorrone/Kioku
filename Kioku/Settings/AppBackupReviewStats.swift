import Foundation

// Stores one backup-safe review-stat snapshot keyed by canonical_entry_id.
struct AppBackupReviewStats: Codable, Hashable {
    let canonicalEntryID: Int64
    let correctCount: Int
    let incorrectCount: Int
    let lastReviewedAt: Date?

    // Creates a flat export record from the in-memory review stats model.
    init(canonicalEntryID: Int64, stats: ReviewWordStats) {
        self.canonicalEntryID = canonicalEntryID
        correctCount = stats.correct
        incorrectCount = stats.again
        lastReviewedAt = stats.lastReviewedAt
    }

    // Rebuilds the runtime review stats model from one backup record.
    func reviewWordStats() -> ReviewWordStats {
        ReviewWordStats(correct: correctCount, again: incorrectCount, lastReviewedAt: lastReviewedAt)
    }
}

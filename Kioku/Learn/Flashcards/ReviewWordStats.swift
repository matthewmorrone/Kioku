import Foundation

// Stores cumulative review results for one word, keyed by canonicalEntryID in ReviewStore.
// Computed properties derive accuracy metrics from the stored counters.
// SRS scheduling fields (`dueDate`, `consecutiveCorrect`) added in Tier 3; older JSON without
// these fields is decoded with defaults so existing review history migrates forward intact.
struct ReviewWordStats: Codable, Hashable {
    var correct: Int
    var again: Int
    var lastReviewedAt: Date?
    // SRS: when this card should next be shown. Nil = never reviewed (treated as immediately due).
    var dueDate: Date?
    // SRS: number of correct answers in a row since the last "again". Drives the interval ladder.
    var consecutiveCorrect: Int

    init(correct: Int, again: Int, lastReviewedAt: Date? = nil, dueDate: Date? = nil, consecutiveCorrect: Int = 0) {
        self.correct = correct
        self.again = again
        self.lastReviewedAt = lastReviewedAt
        self.dueDate = dueDate
        self.consecutiveCorrect = consecutiveCorrect
    }

    // Custom decoder so SRS fields are optional in JSON — pre-Tier-3 review stats stay readable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        correct = try c.decode(Int.self, forKey: .correct)
        again = try c.decode(Int.self, forKey: .again)
        lastReviewedAt = try c.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        consecutiveCorrect = try c.decodeIfPresent(Int.self, forKey: .consecutiveCorrect) ?? 0
    }

    // Total number of review attempts for this word.
    var total: Int { correct + again }

    // Fraction of reviews answered correctly; nil when the word has not yet been reviewed.
    var accuracy: Double? {
        let t = total
        guard t > 0 else { return nil }
        return Double(correct) / Double(t)
    }
}

import Foundation

// Per-(word, direction) evidence, keyed by `QuestionDirection.rawValue` in
// `ReviewWordStats.directionStats`. Tracks the same shape of counters as the whole-word stats but
// scoped to one of the 6 quizzable directions, so graduation can require each direction to clear
// independently instead of being satisfied by a streak in just one.
struct DirectionStats: Codable, Hashable {
    var correct: Int = 0
    var again: Int = 0
    var consecutiveCorrect: Int = 0

    var total: Int { correct + again }
    var accuracy: Double? {
        total > 0 ? Double(correct) / Double(total) : nil
    }
}

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
    // Per-direction evidence, keyed by `QuestionDirection.rawValue`. A direction with no entry has
    // never been answered. Absent from pre-existing JSON; decodes to empty so old history migrates
    // forward intact (see the custom decoder below).
    var directionStats: [String: DirectionStats]
    // Whether the word has a kanji form, learned from whichever study mode last recorded an answer
    // with authoritative dictionary data in hand. Nil means not established yet, which the
    // promotion bars read as "assume it does" — the conservative reading, since wrongly assuming
    // kana-only would relax the bar for a word that genuinely has kanji to learn. Only ever set to
    // `false` by a caller that resolved the word's headword, never inferred from its saved surface
    // (a kana-written surface like ありがとう can still have the headword 有難う).
    var hasKanjiForm: Bool?

    init(
        correct: Int,
        again: Int,
        lastReviewedAt: Date? = nil,
        dueDate: Date? = nil,
        consecutiveCorrect: Int = 0,
        directionStats: [String: DirectionStats] = [:],
        hasKanjiForm: Bool? = nil
    ) {
        self.correct = correct
        self.again = again
        self.lastReviewedAt = lastReviewedAt
        self.dueDate = dueDate
        self.consecutiveCorrect = consecutiveCorrect
        self.directionStats = directionStats
        self.hasKanjiForm = hasKanjiForm
    }

    // Custom decoder so SRS fields are optional in JSON — pre-Tier-3 review stats stay readable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        correct = try c.decode(Int.self, forKey: .correct)
        again = try c.decode(Int.self, forKey: .again)
        lastReviewedAt = try c.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        consecutiveCorrect = try c.decodeIfPresent(Int.self, forKey: .consecutiveCorrect) ?? 0
        directionStats = try c.decodeIfPresent([String: DirectionStats].self, forKey: .directionStats) ?? [:]
        hasKanjiForm = try c.decodeIfPresent(Bool.self, forKey: .hasKanjiForm)
    }

    // Total number of review attempts for this word.
    var total: Int { correct + again }

    // Fraction of reviews answered correctly; nil when the word has not yet been reviewed.
    var accuracy: Double? {
        let t = total
        guard t > 0 else { return nil }
        return Double(correct) / Double(t)
    }

    // Records one answer's outcome against a specific direction's counters, independent of the
    // whole-word counters above (which the caller updates separately). Mirrors the "correct resets
    // nothing, again resets the streak" shape of the whole-word SRS bookkeeping.
    mutating func recordDirectionAnswer(_ direction: QuestionDirection, correct isCorrect: Bool) {
        var ds = directionStats[direction.rawValue] ?? DirectionStats()
        if isCorrect {
            ds.correct += 1
            ds.consecutiveCorrect += 1
        } else {
            ds.again += 1
            ds.consecutiveCorrect = 0
        }
        directionStats[direction.rawValue] = ds
    }
}

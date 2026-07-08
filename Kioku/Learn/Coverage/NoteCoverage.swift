import Foundation

// The computed learning-coverage grid for a single note: its saved words grouped by JLPT level
// and, within each level, by mastery stage, plus note-wide totals. Pure value type produced by
// NoteCoverageCalculator so it is unit-testable without stores or SwiftUI.
struct NoteCoverage: Equatable {

    // One JLPT-level row of the grid. `level` is the JLPT N-number (5…1) or nil for "No level".
    struct Level: Equatable {
        let level: Int?
        let stageWords: [MasteryStage: [SavedWord]]

        // Total words at this level across all stages.
        var total: Int {
            MasteryStage.allCases.reduce(0) { $0 + (stageWords[$1]?.count ?? 0) }
        }

        // Words at this level that have reached the Learned stage.
        var learnedCount: Int { stageWords[.learned]?.count ?? 0 }

        // The words at this level in a given stage (empty when none).
        func words(in stage: MasteryStage) -> [SavedWord] { stageWords[stage] ?? [] }
    }

    // Level rows, ordered easiest → hardest (N5→N1) then No level; only non-empty levels appear.
    let levels: [Level]
    // Total saved words in the note.
    let total: Int
    // How many of them are Learned.
    let learnedCount: Int
    // How many are due for review right now (disjoint from New; see ReviewStore.isDueForReview).
    let dueCount: Int

    // Note-wide learned fraction (0…1); 0 when the note has no words.
    var coverageFraction: Double {
        total == 0 ? 0 : Double(learnedCount) / Double(total)
    }
}

// Builds a NoteCoverage from a word list plus injected lookups. Closures (rather than concrete
// stores) keep it pure and testable: production passes dictionaryStore.jlptLevel / reviewStore
// derivations; tests pass deterministic stubs.
enum NoteCoverageCalculator {

    // Groups words into the (level × stage) grid and tallies note-wide totals. Levels are ordered
    // easiest→hardest (higher N-number first) with No-level (nil) last, and empty levels omitted.
    static func compute(
        words: [SavedWord],
        level: (Int64) -> Int?,
        stage: (Int64) -> MasteryStage,
        isDue: (Int64) -> Bool
    ) -> NoteCoverage {
        var byLevel: [Int?: [MasteryStage: [SavedWord]]] = [:]
        var learnedCount = 0
        var dueCount = 0

        for word in words {
            let id = word.canonicalEntryID
            let lv = level(id)
            let st = stage(id)
            byLevel[lv, default: [:]][st, default: []].append(word)
            if st == .learned { learnedCount += 1 }
            if isDue(id) { dueCount += 1 }
        }

        // Order: non-nil descending (N5=5 … N1=1), then No level (nil) last.
        let orderedKeys = byLevel.keys.sorted { a, b in
            switch (a, b) {
            case let (x?, y?): return x > y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return false
            }
        }

        let levels = orderedKeys.map { key in
            NoteCoverage.Level(level: key, stageWords: byLevel[key] ?? [:])
        }

        return NoteCoverage(
            levels: levels,
            total: words.count,
            learnedCount: learnedCount,
            dueCount: dueCount
        )
    }
}

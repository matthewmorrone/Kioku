import Foundation

// The per-note values the derived sort orders compare. Computed by the caller (NotesView, from
// the word/dictionary stores) and injected here so the ordering itself stays a pure, testable
// function with no store or SwiftUI dependency.
struct NoteSortMetrics: Equatable {
    // Character count of the note's body — the "Longest"/"Shortest" key.
    var length: Int
    // Mean difficulty of the note's saved words on a 1 (N5) … 6 (no JLPT level) scale, or nil
    // when the note has no saved words at all. Notes with nil sort last under both `hardest`
    // and `easiest`: "unknown" is not a difficulty, so it never wins either end.
    var difficulty: Double?
    // Saved words attributed to this note that are not yet Learned or Mastered.
    var wordsLeftToLearn: Int

    init(length: Int = 0, difficulty: Double? = nil, wordsLeftToLearn: Int = 0) {
        self.length = length
        self.difficulty = difficulty
        self.wordsLeftToLearn = wordsLeftToLearn
    }
}

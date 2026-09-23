import Foundation

// One word on a Matching board: the text shown in the left column, the text shown in the right
// column, and what ReviewStore needs to record the result against the word.
struct MatchingPair: Identifiable, Equatable {
    // The word's canonical entry id — also what links a left tile to its right tile.
    let id: Int64
    let prompt: String
    let answer: String
    let hasKanjiForm: Bool
}

// One Matching board: up to five pairs that all quiz the same direction, so each column holds a
// single kind of text (all 漢字, all かな, or all English).
struct MatchingRound: Identifiable, Equatable {
    let id: Int
    let direction: QuestionDirection
    // Left column, top to bottom.
    let pairs: [MatchingPair]
    // Right column, top to bottom, as pair ids — the same words in a shuffled order.
    let answerOrder: [Int64]
}

// Which side of the board a tile sits on.
enum MatchingColumn {
    case prompt
    case answer
}

// How one tile is painted at a given moment.
enum MatchingTileState {
    case idle
    case selected
    case wrong
    case matched
}

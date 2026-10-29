import Foundation

// One row of an expanded breakdown card's split line: the segments one breakdown word (or several
// overlapping ones) covers, side by side, and those words, whose glosses sit to the right. のような
// listed as one word over the segments の | ような is one row, not a gloss on の and an empty ような.
struct SongLineSegmentRow: Equatable {
    // Locations of the row's segment pieces, in line order.
    let pieceLocations: [Int]
    let words: [SongWord]
    // How many identical rows this one stands for; shown as "×N" beside the glosses when above 1.
    var count = 1
    // Segment locations of the folded repeats, so Listen-along still lights this row when it reads one.
    var repeatedLocations: [Int] = []
}

// Where a split-layout child goes (SongLineSplitLayout): its row, and what it is in that row.
nonisolated struct SongLineSplitSlot: Equatable, Sendable {
    let row: Int
    let role: SongLineSplitRole
}

// A split-layout child's part in its row: one of its segments, its glosses, or the band behind the
// whole row that lights up while Listen-along reads it.
nonisolated enum SongLineSplitRole: Equatable, Sendable {
    case segment
    case gloss
    case background
}

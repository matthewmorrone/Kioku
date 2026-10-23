import Foundation

// Where SongLineSegmentsView is between the collapsed sentence and the expanded split.
enum SongLineSegmentsPhase: Equatable {
    // The card's own single-renderer sentence.
    case sentence
    // Segment pieces laid out as the sentence: the start of a split, the end of a collapse.
    case flowing
    // One segment per line, glosses beside them.
    case split
}

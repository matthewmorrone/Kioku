import Foundation

// Pre-resolved per-line furigana payload. The three renderer fields together are exactly
// the data shape `KiokuCoreTextRendererView` consumes, so the card hands them straight
// through with no further conversion. `sourceText` records which line text the cache was
// built from: rows are keyed by line index, and a bare note line's index can later be taken
// by a streamed line with different text, so the cache must be re-validated, not trusted.
struct LineFuriganaCache: Equatable {
    let sourceText: String
    let segmentationRanges: [Range<String.Index>]
    let furiganaBySegmentLocation: [Int: String]
    let furiganaLengthBySegmentLocation: [Int: Int]
}

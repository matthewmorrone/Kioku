import Foundation

// One segment of a breakdown card's Japanese line, cut out with its own furigana so it can be
// drawn and moved on its own (see SongLineSegmentsView). `location` is the segment's UTF-16
// offset in the line, which doubles as its stable identity across the flowing and split layouts.
struct SongLineSegmentPiece: Identifiable, Equatable {
    let location: Int
    let cache: LineFuriganaCache

    var id: Int { location }
}

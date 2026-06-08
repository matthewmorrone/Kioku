import Foundation

// A single furigana (ruby) annotation, stored as UTF-16 offsets relative to the
// parent SegmentRange's surface, half-open [start, end). Relative offsets keep
// annotations stable under text edits outside the segment.
nonisolated struct FuriganaAnnotation: Codable, Equatable, Hashable {
    var start: Int
    var end: Int
    var reading: String
}

import Foundation

// A single furigana (ruby) annotation within a segment, stored as absolute UTF-16 offsets in the note text.
struct FuriganaAnnotation: Codable, Equatable, Hashable {
    var start: Int
    var end: Int
    var reading: String
}

import Foundation

struct SegmentRange: Codable, Equatable {
    var start: Int
    var end: Int

    // Creates a persisted UTF-16 segment range boundary pair.
    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

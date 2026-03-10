import Foundation

struct TokenRange: Codable, Equatable {
    var start: Int
    var end: Int

    // Creates a persisted UTF-16 token range boundary pair.
    init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

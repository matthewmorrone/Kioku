import Foundation

public struct DictionaryEntrySense: Equatable {
    public let pos: String?
    public let glosses: [String]

    // Stores a single ordered sense payload with part-of-speech and gloss lines.
    public init(pos: String?, glosses: [String]) {
        self.pos = pos
        self.glosses = glosses
    }
}

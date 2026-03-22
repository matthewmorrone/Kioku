import Foundation

public struct DictionaryEntrySense: Equatable {
    public let pos: String?
    // Miscellaneous information about this sense (e.g. "uk", "col", "arch"), comma-joined.
    public let misc: String?
    // Field of application (e.g. "math", "music", "med"), comma-joined.
    public let field: String?
    // Dialect or regional usage (e.g. "ksb", "tsug"), comma-joined.
    public let dialect: String?
    public let glosses: [String]

    // Stores a single ordered sense payload with part-of-speech, usage tags, and gloss lines.
    public init(pos: String?, misc: String?, field: String?, dialect: String?, glosses: [String]) {
        self.pos = pos
        self.misc = misc
        self.field = field
        self.dialect = dialect
        self.glosses = glosses
    }
}

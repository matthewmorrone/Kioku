import Foundation

nonisolated public struct DictionaryEntrySense: Equatable, Sendable {
    // Stable per-sense database id; lets saved-word selections reference a sense without
    // depending on its position in the senses array.
    public let senseID: Int64
    public let pos: String?
    // Miscellaneous information about this sense (e.g. "uk", "col", "arch"), comma-joined.
    public let misc: String?
    // Field of application (e.g. "math", "music", "med"), comma-joined.
    public let field: String?
    // Dialect or regional usage (e.g. "ksb", "tsug"), comma-joined.
    public let dialect: String?
    public let glosses: [String]
    // JMdict stagk restrictions: kanji forms this sense applies to. Empty = applies to all kanji forms.
    public let applicableKanji: [String]
    // JMdict stagr restrictions: kana readings this sense applies to. Empty = applies to all readings.
    public let applicableReadings: [String]

    // Stores a single ordered sense payload with part-of-speech, usage tags, and gloss lines.
    public init(
        senseID: Int64,
        pos: String?,
        misc: String?,
        field: String?,
        dialect: String?,
        glosses: [String],
        applicableKanji: [String] = [],
        applicableReadings: [String] = []
    ) {
        self.senseID = senseID
        self.pos = pos
        self.misc = misc
        self.field = field
        self.dialect = dialect
        self.glosses = glosses
        self.applicableKanji = applicableKanji
        self.applicableReadings = applicableReadings
    }
}

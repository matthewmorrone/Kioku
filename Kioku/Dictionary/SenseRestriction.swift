import Foundation

// The two JMdict restriction variants: kanji-form (stagk) or kana-form (stagr).
public enum SenseRestrictionKind: String, Equatable {
    case stagk
    case stagr
}

// A sense-level application restriction indicating which forms a sense applies to.
public struct SenseRestriction: Equatable {
    // Zero-based position of the owning sense within its entry, matching senses.order_index.
    public let senseOrderIndex: Int
    // Whether this restriction targets a kanji form or a kana form.
    public let type: SenseRestrictionKind
    // The specific kanji or kana text that this sense applies to.
    public let value: String

    public init(senseOrderIndex: Int, type: SenseRestrictionKind, value: String) {
        // Stores one JMdict stagk/stagr restriction record linking a sense to a specific form.
        self.senseOrderIndex = senseOrderIndex
        self.type = type
        self.value = value
    }
}

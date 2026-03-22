import Foundation

// A sense-level application restriction (stagk or stagr) indicating which forms a sense applies to.
public struct SenseRestriction: Equatable {
    // Zero-based position of the owning sense within its entry, matching senses.order_index.
    public let senseOrderIndex: Int
    // "stagk" for a kanji-form restriction, "stagr" for a kana-form restriction.
    public let type: String
    // The specific kanji or kana text that this sense applies to.
    public let value: String

    public init(senseOrderIndex: Int, type: String, value: String) {
        // Stores one JMdict stagk/stagr restriction record linking a sense to a specific form.
        self.senseOrderIndex = senseOrderIndex
        self.type = type
        self.value = value
    }
}

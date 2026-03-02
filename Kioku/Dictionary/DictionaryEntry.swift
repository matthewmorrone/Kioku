import Foundation

public struct DictionaryEntry: Equatable {
    public let entryId: Int64
    public let isCommon: Bool
    public let matchedSurface: String
    public let kanjiForms: [String]
    public let kanaForms: [String]
    public let senses: [DictionaryEntrySense]

    public init(
        entryId: Int64,
        isCommon: Bool,
        matchedSurface: String,
        kanjiForms: [String],
        kanaForms: [String],
        senses: [DictionaryEntrySense]
    ) {
        // Captures a fully materialized entry snapshot returned by dictionary lookup.
        self.entryId = entryId
        self.isCommon = isCommon
        self.matchedSurface = matchedSurface
        self.kanjiForms = kanjiForms
        self.kanaForms = kanaForms
        self.senses = senses
    }
}

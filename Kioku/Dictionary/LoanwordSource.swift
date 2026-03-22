import Foundation

// Whether the borrowing covers the full word or only part of it.
public enum LoanwordSourceType: String, Equatable {
    // The entire Japanese word derives from this source.
    case full
    // Only part of the Japanese word derives from this source.
    case part
}

// Loanword source information (JMdict lsource element) for a sense.
public struct LoanwordSource: Equatable {
    // Zero-based position of the owning sense within its entry, matching senses.order_index.
    public let senseOrderIndex: Int
    // ISO 639 language code of the source language (e.g. "eng", "fre", "ger").
    public let lang: String
    // True when the word is a wasei-eigo (Japanese-coined pseudo-loanword).
    public let wasei: Bool
    // Whether the entire word or only part of it derives from this source.
    public let lsType: LoanwordSourceType
    // Source word text in the original language, nil when the element has no content.
    public let content: String?

    public init(senseOrderIndex: Int, lang: String, wasei: Bool, lsType: LoanwordSourceType, content: String?) {
        // Stores one JMdict lsource record describing the foreign-language origin of a sense.
        self.senseOrderIndex = senseOrderIndex
        self.lang = lang
        self.wasei = wasei
        self.lsType = lsType
        self.content = content
    }
}

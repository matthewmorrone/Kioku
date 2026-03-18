import Foundation

public struct DictionaryEntry: Equatable {
    public let entryId: Int64
    // Best JPDB frequency rank for the matched (kanji, kana) pair. Lower = more frequent. Nil if not in JPDB.
    public let jpdbRank: Int?
    // Zipf frequency score from wordfreq for the matched surface. Nil if unscored.
    public let wordfreqZipf: Double?
    public let matchedSurface: String
    public let kanjiForms: [String]
    public let kanaForms: [String]
    public let senses: [DictionaryEntrySense]

    public init(
        entryId: Int64,
        jpdbRank: Int?,
        wordfreqZipf: Double?,
        matchedSurface: String,
        kanjiForms: [String],
        kanaForms: [String],
        senses: [DictionaryEntrySense]
    ) {
        // Captures a fully materialized entry snapshot returned by dictionary lookup.
        self.entryId = entryId
        self.jpdbRank = jpdbRank
        self.wordfreqZipf = wordfreqZipf
        self.matchedSurface = matchedSurface
        self.kanjiForms = kanjiForms
        self.kanaForms = kanaForms
        self.senses = senses
    }
}

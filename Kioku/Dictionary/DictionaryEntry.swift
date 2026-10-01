import Foundation

nonisolated public struct DictionaryEntry: Equatable, Sendable {
    public let entryId: Int64
    // Best frequency rank for the matched (kanji, kana) pair. Lower = more frequent. Nil if unranked.
    public let frequencyRank: Int?
    // Zipf frequency score from wordfreq for the matched surface. Nil if unscored.
    public let wordfreqZipf: Double?
    public let matchedSurface: String
    public let kanjiForms: [KanjiForm]
    public let kanaForms: [KanaForm]
    public let senses: [DictionaryEntrySense]

    public init(
        entryId: Int64,
        frequencyRank: Int?,
        wordfreqZipf: Double?,
        matchedSurface: String,
        kanjiForms: [KanjiForm],
        kanaForms: [KanaForm],
        senses: [DictionaryEntrySense]
    ) {
        // Captures a fully materialized entry snapshot returned by dictionary lookup.
        self.entryId = entryId
        self.frequencyRank = frequencyRank
        self.wordfreqZipf = wordfreqZipf
        self.matchedSurface = matchedSurface
        self.kanjiForms = kanjiForms
        self.kanaForms = kanaForms
        self.senses = senses
    }

    // True when any written or kana form carries a JMdict priority tag (ichi1, news1, spec1, gai1,
    // nfXX) — the dictionary's own mark that a word is in common use. 消す has one; the literary
    // 消する, which 消して also conjugates, has none.
    public var hasPriorityForm: Bool {
        kanjiForms.contains { $0.priority?.isEmpty == false } || kanaForms.contains { $0.priority?.isEmpty == false }
    }

    // Picks the first sense whose JMdict stagk/stagr restrictions are compatible with the given
    // reading and kanji form. See senses(forReading:kanji:) for the matching rules.
    public func sense(forReading reading: String?, kanji: String? = nil) -> DictionaryEntrySense? {
        senses(forReading: reading, kanji: kanji).first
    }

    // Returns every sense whose JMdict stagk/stagr restrictions are compatible with the given
    // reading and kanji form, preserving JMdict order (most common meaning first). A sense matches
    // when its restriction list is empty (applies to all forms) or contains the supplied value.
    // When no sense matches — typically because the caller passed a reading not represented in the
    // entry, e.g. a user-supplied custom reading — falls back to the full sense list so callers
    // still get glosses to display.
    public func senses(forReading reading: String?, kanji: String? = nil) -> [DictionaryEntrySense] {
        let matches = senses.filter { sense in
            let readingOK: Bool
            if sense.applicableReadings.isEmpty {
                readingOK = true
            } else if let reading {
                readingOK = sense.applicableReadings.contains(reading)
            } else {
                readingOK = false
            }
            let kanjiOK: Bool
            if sense.applicableKanji.isEmpty {
                kanjiOK = true
            } else if let kanji {
                kanjiOK = sense.applicableKanji.contains(kanji)
            } else {
                kanjiOK = false
            }
            return readingOK && kanjiOK
        }
        return matches.isEmpty ? senses : matches
    }
}

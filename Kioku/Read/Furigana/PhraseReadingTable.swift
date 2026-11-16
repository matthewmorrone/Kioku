import Foundation

// Which kanji read how inside JMdict's set phrases, from the dictionary's phrase_readings table:
// ざまをみろ holds 態 and 様 read ざま. PhraseReadingEvidence asks it whether a phrase the text spells
// says anything about the kanji it was spelled from, so kana that only happen to line up with a phrase
// (保 read も before に spells にも) cast no vote.
nonisolated final class PhraseReadingTable: Sendable {
    // Phrase spelling → "kanji reading" pairs, joined by a tab.
    private let pairsByPhrase: [String: Set<String>]

    // Builds the table from its rows.
    init(rows: [PhraseReadingRow]) {
        var pairsByPhrase: [String: Set<String>] = [:]
        for row in rows {
            pairsByPhrase[row.phrase, default: []].insert(row.kanji + "\t" + row.reading)
        }
        self.pairsByPhrase = pairsByPhrase
    }

    // The dictionary's table; nil when the dictionary has none or it can't be read, and furigana then
    // weighs no phrases.
    static func load(from store: DictionaryStore) -> PhraseReadingTable? {
        do {
            let rows = try store.fetchPhraseReadings()
            guard rows.isEmpty == false else {
                AppLog.error(.segmentation, "Dictionary has no phrase_readings; furigana weighs no phrases")
                return nil
            }
            return PhraseReadingTable(rows: rows)
        } catch {
            AppLog.error(.segmentation, "phrase_readings failed to load: \(error)")
            return nil
        }
    }

    // True when the set phrase spelled `phrase` reads `kanji` as `reading` (hiragana).
    func phrase(_ phrase: String, reads kanji: String, as reading: String) -> Bool {
        pairsByPhrase[phrase]?.contains(kanji + "\t" + reading) == true
    }
}

import Foundation
import SQLite3

// How kanji read inside JMdict's set phrases (phrase_readings, Resources/generate_db.py
// import_phrase_readings): furigana's phrase evidence (PhraseReadingEvidence) reads it. A dictionary
// built before the table has none, and the phrase evidence then stays silent.
extension DictionaryStore {
    // Every phrase spelling with a kanji run it contains and the run's reading there. Empty without
    // the table.
    nonisolated func fetchPhraseReadings() throws -> [PhraseReadingRow] {
        try withSerializedDatabaseAccess {
            guard tableExists("phrase_readings") else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: "SELECT phrase, kanji, reading FROM phrase_readings", statement: &statement)
            var rows: [PhraseReadingRow] = []
            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                if let phrase = sqlite3_column_text(statement, 0), let kanji = sqlite3_column_text(statement, 1),
                   let reading = sqlite3_column_text(statement, 2) {
                    rows.append(PhraseReadingRow(
                        phrase: String(cString: phrase), kanji: String(cString: kanji), reading: String(cString: reading)
                    ))
                }
                stepCode = sqlite3_step(statement)
            }
            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage()).logged()
            }
            return rows
        }
    }
}

// One phrase_readings row: a spelling of a set phrase, a kanji run in it (or another spelling of that
// run's word), and how the run reads there, in hiragana.
nonisolated struct PhraseReadingRow: Sendable {
    let phrase: String
    let kanji: String
    let reading: String
}

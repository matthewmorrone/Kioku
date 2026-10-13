import Foundation
import SQLite3

// The usage tables Resources/generate_db.py counts from Tatoeba into the dictionary
// (import_usage_tables): the segmenter's class-pair transition costs (segmenter_transitions) and
// furigana's reading counts by neighbouring class (reading_contexts). A dictionary built before them
// has neither; the segmenter then runs without transition costs and furigana keeps frequency order.
extension DictionaryStore {
    // Every class pair's PMI, in nats. Empty without the table.
    nonisolated func fetchSegmenterTransitions() throws -> [SegmenterTransitionRow] {
        try withSerializedDatabaseAccess {
            guard tableExists("segmenter_transitions") else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: "SELECT previous, next, pmi FROM segmenter_transitions", statement: &statement)
            var rows: [SegmenterTransitionRow] = []
            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                if let previous = sqlite3_column_text(statement, 0), let next = sqlite3_column_text(statement, 1) {
                    rows.append(SegmenterTransitionRow(
                        previous: String(cString: previous),
                        next: String(cString: next),
                        pmi: sqlite3_column_double(statement, 2)
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

    // Every kanji run and reading with its count and the "class=count" lists either side. Empty
    // without the table.
    nonisolated func fetchReadingContexts() throws -> [ReadingContextRow] {
        try withSerializedDatabaseAccess {
            guard tableExists("reading_contexts") else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: "SELECT kanji, reading, count, previous, next FROM reading_contexts", statement: &statement)
            var rows: [ReadingContextRow] = []
            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                if let kanji = sqlite3_column_text(statement, 0), let reading = sqlite3_column_text(statement, 1),
                   let previous = sqlite3_column_text(statement, 3), let next = sqlite3_column_text(statement, 4) {
                    rows.append(ReadingContextRow(
                        kanji: String(cString: kanji),
                        reading: String(cString: reading),
                        count: Int(sqlite3_column_int64(statement, 2)),
                        previous: String(cString: previous),
                        next: String(cString: next)
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

// One segmenter_transitions row: how much likelier class `next` is right after class `previous`
// than by chance, as PMI in nats.
nonisolated struct SegmenterTransitionRow: Sendable {
    let previous: String
    let next: String
    let pmi: Double
}

// One reading_contexts row: a kanji run's reading, how often the counts saw it, and the classes seen
// before and after it as "name=count name=count" lists.
nonisolated struct ReadingContextRow: Sendable {
    let kanji: String
    let reading: String
    let count: Int
    let previous: String
    let next: String
}

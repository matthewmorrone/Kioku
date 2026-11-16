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

    // Every kanji run and reading with its count and the "class=count" lists either side, and, from
    // a dictionary that has them, the "class<TAB>lemma=count" word lists either side (empty strings
    // otherwise). Empty without the table.
    nonisolated func fetchReadingContexts() throws -> [ReadingContextRow] {
        try withSerializedDatabaseAccess {
            guard tableExists("reading_contexts") else { return [] }
            let hasNeighbourWords = try readingContextsHaveNeighbourWords()
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let wordColumns = hasNeighbourWords ? ", previous_words, next_words" : ""
            try prepare(sql: "SELECT kanji, reading, count, previous, next\(wordColumns) FROM reading_contexts", statement: &statement)
            // A text column, or "" when the dictionary predates it.
            func text(_ column: Int32) -> String {
                guard hasNeighbourWords, let value = sqlite3_column_text(statement, column) else { return "" }
                return String(cString: value)
            }
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
                        next: String(cString: next),
                        previousWords: text(5),
                        nextWords: text(6)
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

extension DictionaryStore {
    // True when reading_contexts carries the neighbour words. Caller must already hold the queue.
    nonisolated fileprivate func readingContextsHaveNeighbourWords() throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql: "PRAGMA table_info(reading_contexts)", statement: &statement)
        var found = false
        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            // Column 1 of table_info is the column's name.
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == "next_words" { found = true }
            stepCode = sqlite3_step(statement)
        }
        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage()).logged()
        }
        return found
    }
}

// One segmenter_transitions row: how much likelier class `next` is right after class `previous`
// than by chance, as PMI in nats.
nonisolated struct SegmenterTransitionRow: Sendable {
    let previous: String
    let next: String
    let pmi: Double
}

// One reading_contexts row: a kanji run's reading, how often the counts saw it, the classes seen before
// and after it as "name=count name=count" lists, and the same neighbours' words as
// "class<TAB>lemma=count" lists (ReadingNeighbour.wordKey), empty from a dictionary built before them.
nonisolated struct ReadingContextRow: Sendable {
    let kanji: String
    let reading: String
    let count: Int
    let previous: String
    let next: String
    var previousWords = ""
    var nextWords = ""
}

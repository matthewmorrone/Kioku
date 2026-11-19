import Foundation
import SQLite3

// The usage tables Resources/generate_db.py fits from Tatoeba into the dictionary (import_usage_tables):
// the segmenter's class-pair transition costs (segmenter_transitions) and furigana's reading model
// (reading_contexts, word_vectors). A dictionary built before them has neither; the segmenter then
// runs without transition costs and furigana keeps frequency order.
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

    // Every counted kanji-run reading with its count and, where the build fitted a model for the kanji,
    // the model's bias and weights (ReadingContextTable). Empty without the table or from a dictionary
    // that predates the model (its columns).
    nonisolated func fetchReadingContexts() throws -> [ReadingContextRow] {
        try withSerializedDatabaseAccess {
            guard tableExists("reading_contexts"), try tableHasColumn("reading_contexts", "weights") else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: "SELECT kanji, reading, count, bias, weights FROM reading_contexts", statement: &statement)
            var rows: [ReadingContextRow] = []
            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                if let kanji = sqlite3_column_text(statement, 0), let reading = sqlite3_column_text(statement, 1) {
                    rows.append(ReadingContextRow(
                        kanji: String(cString: kanji),
                        reading: String(cString: reading),
                        count: Int(sqlite3_column_int64(statement, 2)),
                        bias: Float(sqlite3_column_double(statement, 3)),
                        weights: blob(statement, 4)
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

    // Every word with its inverse document frequency and quantised vector (WordVectorTable). Empty
    // without the table.
    nonisolated func fetchWordVectors() throws -> [WordVectorRow] {
        try withSerializedDatabaseAccess {
            guard tableExists("word_vectors") else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: "SELECT word, idf, vector FROM word_vectors", statement: &statement)
            var rows: [WordVectorRow] = []
            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                if let word = sqlite3_column_text(statement, 0), let vector = blob(statement, 2) {
                    rows.append(WordVectorRow(word: String(cString: word), inverseDocumentFrequency: sqlite3_column_double(statement, 1), vector: vector))
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
    // True when `table` has a column named `column`. Caller must already hold the queue.
    nonisolated fileprivate func tableHasColumn(_ table: String, _ column: String) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql: "PRAGMA table_info(\(table))", statement: &statement)
        var found = false
        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            // Column 1 of table_info is the column's name.
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column { found = true }
            stepCode = sqlite3_step(statement)
        }
        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage()).logged()
        }
        return found
    }

    // The bytes of a BLOB column, or nil when it is NULL.
    nonisolated fileprivate func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

// One segmenter_transitions row: how much likelier class `next` is right after class `previous`
// than by chance, as PMI in nats.
nonisolated struct SegmenterTransitionRow: Sendable {
    let previous: String
    let next: String
    let pmi: Double
}

// One reading_contexts row: a kanji run's reading, how often the counts saw it, and, for a kanji with a
// model, its bias and its ReadingContext.featureCount little-endian Float32 weights.
nonisolated struct ReadingContextRow: Sendable {
    let kanji: String
    let reading: String
    let count: Int
    let bias: Float
    let weights: Data?
}

// One word_vectors row: a word, its inverse document frequency in the counted sentences and its
// WordVectorTable.dimensions quantised components.
nonisolated struct WordVectorRow: Sendable {
    let word: String
    let inverseDocumentFrequency: Double
    let vector: Data
}

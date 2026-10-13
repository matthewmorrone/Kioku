import Foundation
import SQLite3

// The register tables Resources/generate_db.py builds into the dictionary (import_reading_registers): reading counts from web
// and literary text (reading_register_counts), and the character-gram counts RegisterClassifier tells a
// note's register by (register_grams, register_totals). A dictionary built before them has none, and
// furigana then counts Tatoeba alone.
extension DictionaryStore {
    // Reading counts by register, then kanji run, then hiragana reading. Empty without the table.
    nonisolated func fetchReadingRegisterCounts() throws -> [String: [String: [String: Int]]] {
        try withSerializedDatabaseAccess {
            guard tableExists("reading_register_counts") else { return [:] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: "SELECT register, kanji, reading, count FROM reading_register_counts", statement: &statement)
            var counts: [String: [String: [String: Int]]] = [:]
            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                if let register = sqlite3_column_text(statement, 0), let kanji = sqlite3_column_text(statement, 1),
                   let reading = sqlite3_column_text(statement, 2) {
                    counts[String(cString: register), default: [:]][String(cString: kanji), default: [:]][String(cString: reading)] =
                        Int(sqlite3_column_int64(statement, 3))
                }
                stepCode = sqlite3_step(statement)
            }
            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage()).logged()
            }
            return counts
        }
    }

    // The classifier's gram counts, one column per register, with each register's total and the
    // vocabulary size the smoothing needs. Nil without the tables.
    nonisolated func fetchRegisterGramCounts() throws -> RegisterGramCounts? {
        try withSerializedDatabaseAccess {
            guard tableExists("register_grams"), tableExists("register_totals") else { return nil }
            var totalsStatement: OpaquePointer?
            defer { sqlite3_finalize(totalsStatement) }
            try prepare(sql: "SELECT register, grams, vocabulary FROM register_totals ORDER BY register", statement: &totalsStatement)
            var registers: [String] = []
            var totals: [Int] = []
            var vocabulary = 0
            var stepCode = sqlite3_step(totalsStatement)
            while stepCode == SQLITE_ROW {
                if let register = sqlite3_column_text(totalsStatement, 0) {
                    registers.append(String(cString: register))
                    totals.append(Int(sqlite3_column_int64(totalsStatement, 1)))
                    vocabulary = Int(sqlite3_column_int64(totalsStatement, 2))
                }
                stepCode = sqlite3_step(totalsStatement)
            }
            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage()).logged()
            }
            // The column names are the register names, read in the totals' order.
            var gramsStatement: OpaquePointer?
            defer { sqlite3_finalize(gramsStatement) }
            try prepare(sql: "SELECT gram, \(registers.joined(separator: ", ")) FROM register_grams", statement: &gramsStatement)
            var counts: [String: [Int]] = [:]
            stepCode = sqlite3_step(gramsStatement)
            while stepCode == SQLITE_ROW {
                if let gram = sqlite3_column_text(gramsStatement, 0) {
                    counts[String(cString: gram)] = registers.indices.map { Int(sqlite3_column_int64(gramsStatement, Int32($0) + 1)) }
                }
                stepCode = sqlite3_step(gramsStatement)
            }
            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage()).logged()
            }
            return RegisterGramCounts(registers: registers, counts: counts, totals: totals, vocabulary: vocabulary)
        }
    }
}

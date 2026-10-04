import Foundation
import SQLite3

// The dictionary's hand-added words: the entries extras.json contributes at build time, which the
// builder gives negative ent_seqs. Learned new words also carry negative ent_seqs, below
// LearnedWordApplier's base, and are excluded here (Custom Words lists them from LearnedWordStore).
extension DictionaryStore {
    // Every extras.json entry in this dictionary, in the order the builder wrote them.
    nonisolated func fetchBuiltInCustomEntries() throws -> [DictionaryEntry] {
        let entryIDs: [Int64] = try withSerializedDatabaseAccess {
            let sql = "SELECT id FROM entries WHERE ent_seq < 0 AND ent_seq > -10000000000 ORDER BY id"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            return try stepRows(statement: statement) { stmt in
                Int64(sqlite3_column_int64(stmt, 0))
            }
        }
        return try entryIDs.compactMap { try lookupEntry(entryID: $0) }
    }
}

import Foundation
import SQLite3

// Reads back which Custom Words list was last written into the dictionary file.
extension DictionaryStore {
    // CustomWordApplier's signature of the applied list (custom_word_state), nil before any list
    // was applied. Part of TrieSnapshotCache.key, since the words become trie surfaces.
    nonisolated func customWordSignature() -> String? {
        withSerializedDatabaseAccess {
            guard tableExists("custom_word_state") else { return nil }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            do {
                try prepare(sql: "SELECT signature FROM custom_word_state LIMIT 1", statement: &statement)
            } catch {
                AppLog.error(.dictionary, "Custom word signature unreadable: \(error)")
                return nil
            }
            let stepCode = sqlite3_step(statement)
            guard stepCode == SQLITE_ROW else {
                if stepCode != SQLITE_DONE {
                    AppLog.error(.dictionary, "Custom word signature unreadable: \(errorMessage())")
                }
                return nil
            }
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        }
    }
}

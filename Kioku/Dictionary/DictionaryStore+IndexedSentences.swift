import Foundation
import SQLite3

// Example sentences found through the sentence_tokens table Resources/generate_db.py builds from
// Tatoeba's Japanese indices (import_sentence_tokens): which dictionary entries each sentence uses, and
// how each is written there.
// A dictionary built before the table has none, and callers fall back to the spelling scan.
extension DictionaryStore {
    // Sentences whose tokens include the entry, shortest first, capped at 20. Matches the word itself
    // (痛み) and its inflections, never another word that merely contains its spelling (痛みます is 痛む).
    // Empty without the table or when the entry has no indexed sentence.
    nonisolated public func fetchIndexedSentencePairs(entryID: Int64) throws -> [SentencePair] {
        try withSerializedDatabaseAccess {
            guard tableExists("sentence_tokens") else { return [] }
            let sql = """
            SELECT sp.japanese, sp.english, st.surface
            FROM sentence_tokens st
            JOIN sentence_pairs sp ON sp.ja_id = st.ja_id
            WHERE st.entry_id = ?1
            ORDER BY LENGTH(sp.japanese) ASC
            LIMIT 40
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            try bindInt64(entryID, index: 1, statement: statement)
            let rows = try stepRows(statement: statement) { stmt -> SentencePair? in
                guard
                    let japanesePointer = sqlite3_column_text(stmt, 0),
                    let englishPointer = sqlite3_column_text(stmt, 1),
                    let surfacePointer = sqlite3_column_text(stmt, 2)
                else { return nil }
                return SentencePair(
                    japanese: String(cString: japanesePointer),
                    english: String(cString: englishPointer),
                    highlight: String(cString: surfacePointer)
                )
            }
            // A sentence with several translations comes back once per translation.
            return Array(SentencePairDedup.dedupe(rows).prefix(20))
        }
    }
}

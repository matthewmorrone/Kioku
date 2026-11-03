import Foundation
import SQLite3

// Query surface for kanji etymology, backed by the `kanji_etymology` table that generate_db.py fills
// from Wiktionary's "Glyph origin" sections (see Resources/kanji_etymology.py).
extension DictionaryStore {

    // The etymology text for one kanji, or nil when Wiktionary has no section for it that converted
    // without losing content, or the dictionary was built before the table existed. Powers the
    // Etymology section of the kanji detail sheet.
    nonisolated func fetchKanjiEtymology(for literal: String) throws -> String? {
        try withSerializedDatabaseAccess {
            guard tableExists("kanji_etymology") else { return nil }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: "SELECT text FROM kanji_etymology WHERE literal = ?1", statement: &statement)
            try bindText(literal, index: 1, statement: statement)
            return try stepRows(statement: statement) { stmt -> String? in
                sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            }.first
        }
    }
}

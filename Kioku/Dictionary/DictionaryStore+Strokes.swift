import Foundation
import SQLite3

// Query surface for KanjiVG stroke data. Backed by the `kanji_strokes` table populated from
// kanjivg.xml at DB-generation time.
extension DictionaryStore {

    // One stroke's SVG path data plus its 1-based order in the kanji's canonical writing sequence.
    nonisolated public struct KanjiStrokeRecord: Equatable, Hashable {
        public let order: Int
        public let pathD: String
    }

    // Returns the canonical strokes for one kanji character ordered 1..N, or [] if the kanji
    // isn't in the KanjiVG dataset (or the data wasn't imported into the DB build).
    nonisolated func fetchKanjiStrokes(for literal: String) throws -> [KanjiStrokeRecord] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT stroke_order, path_d
            FROM kanji_strokes
            WHERE kanji = ?1
            ORDER BY stroke_order ASC
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            try bindText(literal, index: 1, statement: statement)

            return try stepRows(statement: statement) { stmt -> KanjiStrokeRecord? in
                guard let dPointer = sqlite3_column_text(stmt, 1) else { return nil }
                let order = Int(sqlite3_column_int(stmt, 0))
                let d = String(cString: dPointer)
                return KanjiStrokeRecord(order: order, pathD: d)
            }
        }
    }
}

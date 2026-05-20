import Foundation
import SQLite3

// Query surface for the multi-radical kanji input view.
// Backed by RADKFILE2/KRADFILE2 data populated into `radicals` and `kanji_radicals` by generate_db.py.
extension DictionaryStore {

    // All radical components in the inventory, ordered by stroke count then glyph for stable grid layout.
    // Returns an empty array if the radical tables weren't populated (e.g. RADKFILE2 files absent at build time).
    nonisolated func fetchAllRadicals() throws -> [Radical] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT radical, stroke_count
            FROM radicals
            ORDER BY stroke_count ASC, radical ASC
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)

            return try stepRows(statement: statement) { stmt -> Radical? in
                guard let glyphPointer = sqlite3_column_text(stmt, 0) else { return nil }
                let glyph = String(cString: glyphPointer)
                let strokes = Int(sqlite3_column_int(stmt, 1))
                return Radical(glyph: glyph, strokeCount: strokes)
            }
        }
    }

    // The set of kanji that contain ALL of the given radicals. Empty selection returns empty set —
    // the UI is responsible for refusing to show an unbounded result list.
    nonisolated func fetchKanjiContainingAllRadicals(_ radicalGlyphs: [String]) throws -> [String] {
        guard radicalGlyphs.isEmpty == false else { return [] }
        return try withSerializedDatabaseAccess {
            // GROUP BY kanji with HAVING count = N gives the intersection of "kanji containing X"
            // sets for each X in the selection. The IN(...) list expands to one placeholder per
            // radical so the prepared statement can bind them positionally.
            let placeholders = Array(repeating: "?", count: radicalGlyphs.count).joined(separator: ",")
            let sql = """
            SELECT kanji
            FROM kanji_radicals
            WHERE radical IN (\(placeholders))
            GROUP BY kanji
            HAVING COUNT(DISTINCT radical) = ?\(radicalGlyphs.count + 1)
            ORDER BY kanji
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            for (index, glyph) in radicalGlyphs.enumerated() {
                try bindText(glyph, index: Int32(index + 1), statement: statement)
            }
            try bindInt64(Int64(radicalGlyphs.count), index: Int32(radicalGlyphs.count + 1), statement: statement)

            return try stepRows(statement: statement) { stmt -> String? in
                sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            }
        }
    }

    // The radicals that still appear in at least one kanji from the current candidate set.
    // Used by the input UI to dim radicals that would empty the result if added — same affordance
    // Nihongo and similar apps use to guide multi-radical selection.
    nonisolated func fetchUsableRadicals(currentSelection: [String]) throws -> Set<String> {
        // No selection ⇒ every radical is usable.
        guard currentSelection.isEmpty == false else {
            let all = try fetchAllRadicals()
            return Set(all.map(\.glyph))
        }

        let candidateKanji = try fetchKanjiContainingAllRadicals(currentSelection)
        guard candidateKanji.isEmpty == false else { return [] }

        return try withSerializedDatabaseAccess {
            let placeholders = Array(repeating: "?", count: candidateKanji.count).joined(separator: ",")
            let sql = """
            SELECT DISTINCT radical
            FROM kanji_radicals
            WHERE kanji IN (\(placeholders))
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            for (index, kanji) in candidateKanji.enumerated() {
                try bindText(kanji, index: Int32(index + 1), statement: statement)
            }
            let rows = try stepRows(statement: statement) { stmt -> String? in
                sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            }
            return Set(rows)
        }
    }
}

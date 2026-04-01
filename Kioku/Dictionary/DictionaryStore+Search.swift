import Foundation
import SQLite3

// Search query surface used by the Words tab for explicit Japanese and English lookup modes.
extension DictionaryStore {
    // Executes one Words-tab dictionary search in the requested language mode.
    func searchEntries(term: String, mode: DictionarySearchMode, limit: Int = 100) throws -> [DictionaryEntry] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        switch mode {
        case .japanese:
            return try searchJapaneseEntries(term: trimmed)
        case .english:
            return try searchEnglishEntries(term: trimmed, limit: limit)
        }
    }

    // Performs the Japanese surface/reading search behavior already used by the Words tab.
    private func searchJapaneseEntries(term: String) throws -> [DictionaryEntry] {
        var entries: [DictionaryEntry] = []
        if ScriptClassifier.containsKanji(term) {
            entries += try lookup(surface: term, mode: .kanjiAndKana)
        }
        entries += try lookup(surface: term, mode: .kanaOnly)

        var seen = Set<Int64>()
        return entries.filter { seen.insert($0.entryId).inserted }
    }

    // Performs English gloss search first, then materializes entries in ranked order.
    private func searchEnglishEntries(term: String, limit: Int) throws -> [DictionaryEntry] {
        let entryIDs = try matchingEnglishEntryIDs(term: term, limit: limit)
        var entries: [DictionaryEntry] = []
        entries.reserveCapacity(entryIDs.count)

        for entryID in entryIDs {
            if let entry = try lookupEntry(entryID: entryID) {
                entries.append(entry)
            }
        }

        return entries
    }

    // Returns ranked entry ids whose English glosses contain the search term.
    private func matchingEnglishEntryIDs(term: String, limit: Int) throws -> [Int64] {
        try withSerializedDatabaseAccess {
            let normalizedTerm = term.lowercased()
            let containsPattern = "%\(normalizedTerm)%"
            let prefixPattern = "\(normalizedTerm)%"
            let wordBoundaryPattern = "% \(normalizedTerm)%"
            let sql = """
            SELECT
                s.entry_id,
                MIN(
                    CASE
                        WHEN LOWER(g.text) = ?2 THEN 0
                        WHEN LOWER(g.text) LIKE ?3 THEN 1
                        WHEN LOWER(g.text) LIKE ?4 THEN 2
                        ELSE 3
                    END
                ) AS match_bucket
            FROM glosses g
            JOIN senses s ON s.id = g.sense_id
            WHERE LOWER(g.text) LIKE ?1
            GROUP BY s.entry_id
            ORDER BY match_bucket ASC, s.entry_id ASC
            LIMIT ?5
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindText(containsPattern, index: 1, statement: statement)
            try bindText(normalizedTerm, index: 2, statement: statement)
            try bindText(prefixPattern, index: 3, statement: statement)
            try bindText(wordBoundaryPattern, index: 4, statement: statement)
            try bindInt64(Int64(limit), index: 5, statement: statement)

            return try stepRows(statement: statement) { stmt in
                Int64(sqlite3_column_int64(stmt, 0))
            }
        }
    }
}

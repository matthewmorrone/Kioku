import Foundation
import SQLite3

// Search query surface used by the Words tab for explicit Japanese and English lookup modes.
extension DictionaryStore {
    // Executes one Words-tab dictionary search in the requested language mode.
    nonisolated func searchEntries(term: String, mode: DictionarySearchMode, limit: Int = 100) throws -> [DictionaryEntry] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        switch mode {
        case .japanese:
            return try searchJapaneseEntries(term: trimmed)
        case .english:
            return try searchEnglishEntries(term: trimmed, limit: limit)
        }
    }

    // Returns up to `limit` entries whose kanji form contains the given character, ordered by
    // best JPDB rank so the most common words containing this kanji appear first.
    // Used by the standalone kanji detail page to surface example words.
    nonisolated func searchEntriesContainingKanji(literal: String, limit: Int = 100) throws -> [DictionaryEntry] {
        let trimmed = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        let pattern = "%\(trimmed.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_"))%"

        let entryIDs: [Int64] = try withSerializedDatabaseAccess {
            let sql = """
            SELECT k.entry_id, MIN(wf.jpdb_rank) AS best_rank
            FROM kanji k
            LEFT JOIN word_frequency wf ON wf.entry_id = k.entry_id
            WHERE k.text LIKE ?1 ESCAPE '\\'
            GROUP BY k.entry_id
            ORDER BY (best_rank IS NULL) ASC, best_rank ASC, k.entry_id ASC
            LIMIT ?2
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            try bindText(pattern, index: 1, statement: statement)
            try bindInt64(Int64(limit), index: 2, statement: statement)

            return try stepRows(statement: statement) { stmt in
                Int64(sqlite3_column_int64(stmt, 0))
            }
        }

        var results: [DictionaryEntry] = []
        results.reserveCapacity(entryIDs.count)
        for entryID in entryIDs {
            if let entry = try lookupEntry(entryID: entryID) {
                results.append(entry)
            }
        }
        return results
    }

    // Executes a kana/kanji LIKE search using user-facing `?` (one char) and `*` (any chars) wildcards.
    // Returns up to `limit` entries that match the pattern against either kana_forms or kanji surfaces.
    nonisolated func searchEntriesByPattern(_ pattern: String, limit: Int = 200) throws -> [DictionaryEntry] {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        guard trimmed.contains("*") || trimmed.contains("?") else { return [] }
        // Reject pure-wildcard patterns to avoid scanning the entire dictionary.
        guard trimmed.contains(where: { $0 != "*" && $0 != "?" }) else { return [] }

        let sqlPattern = sqlLikePattern(from: trimmed)
        let entryIDs = try matchingPatternEntryIDs(sqlPattern: sqlPattern, limit: limit)

        var entries: [DictionaryEntry] = []
        entries.reserveCapacity(entryIDs.count)
        for entryID in entryIDs {
            if let entry = try lookupEntry(entryID: entryID) {
                entries.append(entry)
            }
        }
        return entries
    }

    // Performs the Japanese surface/reading search behavior already used by the Words tab.
    nonisolated private func searchJapaneseEntries(term: String) throws -> [DictionaryEntry] {
        var entries: [DictionaryEntry] = []
        if ScriptClassifier.containsKanji(term) {
            entries += try lookup(surface: term, mode: .kanjiAndKana)
        }
        entries += try lookup(surface: term, mode: .kanaOnly)

        var seen = Set<Int64>()
        return entries.filter { seen.insert($0.entryId).inserted }
    }

    // Performs English gloss search first, then materializes entries in ranked order.
    nonisolated private func searchEnglishEntries(term: String, limit: Int) throws -> [DictionaryEntry] {
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

    // Translates user wildcards (`?`, `*`) to SQL LIKE wildcards (`_`, `%`), escaping literal `%`/`_`/`\`.
    nonisolated private func sqlLikePattern(from input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        for character in input {
            switch character {
            case "*": result.append("%")
            case "?": result.append("_")
            case "%", "_", "\\":
                result.append("\\")
                result.append(character)
            default:
                result.append(character)
            }
        }
        return result
    }

    // Returns deduplicated entry ids whose kana or kanji surfaces match the SQL LIKE pattern.
    nonisolated private func matchingPatternEntryIDs(sqlPattern: String, limit: Int) throws -> [Int64] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT entry_id FROM (
                SELECT entry_id FROM kana_forms WHERE text LIKE ?1 ESCAPE '\\'
                UNION
                SELECT entry_id FROM kanji WHERE text LIKE ?1 ESCAPE '\\'
            )
            ORDER BY entry_id ASC
            LIMIT ?2
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindText(sqlPattern, index: 1, statement: statement)
            try bindInt64(Int64(limit), index: 2, statement: statement)

            return try stepRows(statement: statement) { stmt in
                Int64(sqlite3_column_int64(stmt, 0))
            }
        }
    }

    // Returns ranked entry ids whose English glosses contain the search term.
    nonisolated private func matchingEnglishEntryIDs(term: String, limit: Int) throws -> [Int64] {
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

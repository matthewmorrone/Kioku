import Foundation
import SQLite3

// Search query surface used by the Words tab for explicit Japanese and English lookup modes.
extension DictionaryStore {
    // Executes one Words-tab dictionary search in the requested language mode.
    nonisolated func searchEntries(term: String, mode: DictionarySearchMode, limit: Int = 25) throws -> [DictionaryEntry] {
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

    // Performs the Words-tab Japanese search: exact lookup first (preserves variant
    // expansion + correct ordering), then a substring SQL fan-out so partial queries
    // like `食` surface 食べる, 食事, 食堂, etc. Skipped entirely for queries that contain
    // no Japanese characters — running a `LIKE '%hello%'` against 489k kanji/kana rows is
    // 4–8 seconds on-device and can never match.
    nonisolated private func searchJapaneseEntries(term: String) throws -> [DictionaryEntry] {
        guard containsJapaneseScript(term) else { return [] }

        var entries: [DictionaryEntry] = []
        if ScriptClassifier.containsKanji(term) {
            entries += try lookup(surface: term, mode: .kanjiAndKana)
        }
        entries += try lookup(surface: term, mode: .kanaOnly)

        var seen = Set<Int64>()
        var deduped = entries.filter { seen.insert($0.entryId).inserted }

        // Append substring hits, frequency-ordered, that weren't already in the exact set.
        let substringIDs = try matchingJapaneseSubstringEntryIDs(term: term, limit: 25)
        let freshIDs = substringIDs.filter { seen.insert($0).inserted }
        deduped.append(contentsOf: try lookupEntries(entryIDs: freshIDs))
        return deduped
    }

    // True if any character in the term is Hiragana, Katakana, or CJK Unified Ideographs.
    // Cheap O(n) Unicode-range scan; used to gate Japanese-side SQL scans for ASCII queries.
    nonisolated private func containsJapaneseScript(_ term: String) -> Bool {
        for scalar in term.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x309F).contains(v) { return true }  // Hiragana
            if (0x30A0...0x30FF).contains(v) { return true }  // Katakana
            if (0x4E00...0x9FFF).contains(v) { return true }  // CJK Unified Ideographs
            if (0x3400...0x4DBF).contains(v) { return true }  // CJK Extension A
            if (0xFF66...0xFF9D).contains(v) { return true }  // Halfwidth katakana
        }
        return false
    }

    // Returns entry ids whose kanji surface OR kana form contains the literal term as
    // a substring, ordered by best JPDB frequency rank (most common first).
    //
    // Path depends on term length:
    //   • ≥ 3 chars → FTS5 trigram MATCH (sub-millisecond, indexed)
    //   • 1–2 chars → B-tree prefix LIKE 'term%' (the trigram tokenizer requires 3 chars
    //     so substring lookup isn't available; we degrade to prefix-only, which is the
    //     query the user usually wants for 1-char kanji anyway: 食 → 食べる, 食事, …)
    nonisolated private func matchingJapaneseSubstringEntryIDs(term: String, limit: Int) throws -> [Int64] {
        if term.count >= 3 {
            return try matchingJapaneseFTSEntryIDs(term: term, limit: limit)
        }
        return try matchingJapanesePrefixEntryIDs(term: term, limit: limit)
    }

    // Substring lookup against the trigram FTS5 index over kanji + kana_forms. O(log n).
    nonisolated private func matchingJapaneseFTSEntryIDs(term: String, limit: Int) throws -> [Int64] {
        try withSerializedDatabaseAccess {
            let matchToken = ftsPhraseToken(for: term)
            let sql = """
            SELECT entry_id, MIN(best_rank) AS best_rank FROM (
                SELECT k.entry_id, MIN(wf.jpdb_rank) AS best_rank
                FROM kanji_fts JOIN kanji k ON k.id = kanji_fts.rowid
                LEFT JOIN word_frequency wf ON wf.entry_id = k.entry_id
                WHERE kanji_fts MATCH ?1
                GROUP BY k.entry_id
                UNION ALL
                SELECT kf.entry_id, MIN(wf.jpdb_rank) AS best_rank
                FROM kana_forms_fts JOIN kana_forms kf ON kf.id = kana_forms_fts.rowid
                LEFT JOIN word_frequency wf ON wf.entry_id = kf.entry_id
                WHERE kana_forms_fts MATCH ?1
                GROUP BY kf.entry_id
            )
            GROUP BY entry_id
            ORDER BY (best_rank IS NULL) ASC, best_rank ASC, entry_id ASC
            LIMIT ?2
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            try bindText(matchToken, index: 1, statement: statement)
            try bindInt64(Int64(limit), index: 2, statement: statement)

            return try stepRows(statement: statement) { stmt in
                Int64(sqlite3_column_int64(stmt, 0))
            }
        }
    }

    // Prefix-only fallback for 1–2 char Japanese queries that the trigram index can't represent.
    // Uses idx_kanji_text / idx_kana_text for an indexed range scan.
    nonisolated private func matchingJapanesePrefixEntryIDs(term: String, limit: Int) throws -> [Int64] {
        try withSerializedDatabaseAccess {
            let pattern = "\(escapeLikeLiteral(term))%"
            let sql = """
            SELECT entry_id, MIN(best_rank) AS best_rank FROM (
                SELECT k.entry_id, MIN(wf.jpdb_rank) AS best_rank
                FROM kanji k
                LEFT JOIN word_frequency wf ON wf.entry_id = k.entry_id
                WHERE k.text LIKE ?1 ESCAPE '\\'
                GROUP BY k.entry_id
                UNION ALL
                SELECT kf.entry_id, MIN(wf.jpdb_rank) AS best_rank
                FROM kana_forms kf
                LEFT JOIN word_frequency wf ON wf.entry_id = kf.entry_id
                WHERE kf.text LIKE ?1 ESCAPE '\\'
                GROUP BY kf.entry_id
            )
            GROUP BY entry_id
            ORDER BY (best_rank IS NULL) ASC, best_rank ASC, entry_id ASC
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
    }

    // Wraps a search term in double quotes so FTS5 treats it as a literal phrase. Quotes
    // inside the term are escaped by doubling, matching FTS5's quote-escape rules. This
    // means special FTS5 operators like AND, OR, NEAR, and column filters are not invoked
    // by the user accidentally typing them.
    nonisolated private func ftsPhraseToken(for term: String) -> String {
        "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // Escapes SQL LIKE metacharacters in a literal user-supplied term so they're matched
    // as text rather than treated as wildcards. Backslash is the ESCAPE char in our LIKE
    // expressions, so it must be doubled too.
    nonisolated private func escapeLikeLiteral(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        for character in input {
            switch character {
            case "\\", "%", "_":
                result.append("\\")
                result.append(character)
            default:
                result.append(character)
            }
        }
        return result
    }

    // Performs English gloss search first, then materializes entries in ranked order.
    // Skipped entirely for queries that contain Japanese characters — JMdict glosses are
    // ASCII/Latin, so a kanji or kana substring can never match a gloss row, and the LIKE
    // scan over 432k glosses would burn 2–4 seconds for guaranteed-empty results.
    nonisolated private func searchEnglishEntries(term: String, limit: Int) throws -> [DictionaryEntry] {
        guard containsJapaneseScript(term) == false else { return [] }
        let entryIDs = try matchingEnglishEntryIDs(term: term, limit: limit)
        return try lookupEntries(entryIDs: entryIDs)
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
    //
    // For ≥ 3 chars: FTS5 trigram MATCH against `glosses_fts`, then rank exact /
    // prefix / word-boundary / substring with a CASE in the SELECT so the join with
    // `glosses` resolves the actual text for tiebreaking. Sub-millisecond on-device.
    //
    // For 1–2 chars: trigram can't index those, so fall back to the slow LIKE scan —
    // these queries are rare (search field starts empty and grows) and finish before
    // the user types a third character anyway.
    nonisolated private func matchingEnglishEntryIDs(term: String, limit: Int) throws -> [Int64] {
        if term.count >= 3 {
            return try matchingEnglishFTSEntryIDs(term: term, limit: limit)
        }
        return try matchingEnglishScanEntryIDs(term: term, limit: limit)
    }

    // English substring lookup via the trigram FTS5 index over glosses. CASE expression
    // ranks exact / prefix / word-boundary / generic-substring hits in that order.
    nonisolated private func matchingEnglishFTSEntryIDs(term: String, limit: Int) throws -> [Int64] {
        // Two-phase ranking: first try word-boundary matches only — entries where the
        // term appears as a standalone word, or as the canonical "to <term>" verb form.
        // Trigram substring (e.g. "eat" matching "eating", "create", "feature") is the
        // fallback path used only when no word-boundary hit exists.
        let wordBoundary = try runEnglishFTSQuery(term: term, limit: limit, requireWordBoundary: true)
        if wordBoundary.isEmpty == false {
            return wordBoundary
        }
        return try runEnglishFTSQuery(term: term, limit: limit, requireWordBoundary: false)
    }

    // Runs the FTS5 trigram query with an optional HAVING clause that excludes the
    // generic-substring bucket. Both phases share the same SQL shape so the prepared
    // statement layout (and bucket ordering) stays identical.
    nonisolated private func runEnglishFTSQuery(term: String, limit: Int, requireWordBoundary: Bool) throws -> [Int64] {
        try withSerializedDatabaseAccess {
            let normalizedTerm = term.lowercased()
            let matchToken = ftsPhraseToken(for: normalizedTerm)
            // JMdict verb glosses follow "to <verb>" convention ("to eat", "to drink").
            // Bucket logic treats those infinitive forms as canonical.
            let exactTerm = normalizedTerm
            let exactVerbTerm = "to \(normalizedTerm)"
            // Bucket 1 patterns: term (or "to term") at start of gloss, followed by a space.
            // The trailing space is what enforces word boundary — "eat " excludes "eating".
            let openingPattern = "\(normalizedTerm) %"
            let openingVerbPattern = "to \(normalizedTerm) %"
            // Bucket 2 patterns: term as last word (' eat') or middle word (' eat ' or ' eat,').
            // Leading space requires the previous character to be whitespace.
            let trailingPattern = "% \(normalizedTerm)"
            let trailingVerbPattern = "% to \(normalizedTerm)"
            let middlePattern = "% \(normalizedTerm) %"
            let middleVerbPattern = "% to \(normalizedTerm) %"
            // Buckets:
            //   0 = gloss IS the term (or "to <term>")
            //   1 = term starts the gloss as its own word ("eat ..." or "to eat ...")
            //   2 = term appears as a complete word elsewhere in the gloss
            //   3 = trigram hit only (substring inside another word — "eating", "create", ...)
            let havingClause = requireWordBoundary ? "HAVING match_bucket < 3" : ""
            let sql = """
            SELECT
                s.entry_id,
                MIN(
                    CASE
                        WHEN LOWER(g.gloss) = ?2 OR LOWER(g.gloss) = ?3 THEN 0
                        WHEN LOWER(g.gloss) LIKE ?4 OR LOWER(g.gloss) LIKE ?5 THEN 1
                        WHEN LOWER(g.gloss) LIKE ?6 OR LOWER(g.gloss) LIKE ?7
                          OR LOWER(g.gloss) LIKE ?8 OR LOWER(g.gloss) LIKE ?9 THEN 2
                        ELSE 3
                    END
                ) AS match_bucket,
                MIN(wf.jpdb_rank) AS best_rank
            FROM glosses_fts
            JOIN glosses g ON g.id = glosses_fts.rowid
            JOIN senses s ON s.id = g.sense_id
            LEFT JOIN word_frequency wf ON wf.entry_id = s.entry_id
            WHERE glosses_fts MATCH ?1
            GROUP BY s.entry_id
            \(havingClause)
            ORDER BY match_bucket ASC, (best_rank IS NULL) ASC, best_rank ASC, s.entry_id ASC
            LIMIT ?10
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindText(matchToken, index: 1, statement: statement)
            try bindText(exactTerm, index: 2, statement: statement)
            try bindText(exactVerbTerm, index: 3, statement: statement)
            try bindText(openingPattern, index: 4, statement: statement)
            try bindText(openingVerbPattern, index: 5, statement: statement)
            try bindText(trailingPattern, index: 6, statement: statement)
            try bindText(trailingVerbPattern, index: 7, statement: statement)
            try bindText(middlePattern, index: 8, statement: statement)
            try bindText(middleVerbPattern, index: 9, statement: statement)
            try bindInt64(Int64(limit), index: 10, statement: statement)

            return try stepRows(statement: statement) { stmt in
                Int64(sqlite3_column_int64(stmt, 0))
            }
        }
    }

    // Pre-trigram fallback for 1–2 char English queries that trigram FTS5 can't index.
    // Full scan over glosses, but rare in practice — search terms grow past 2 chars quickly.
    nonisolated private func matchingEnglishScanEntryIDs(term: String, limit: Int) throws -> [Int64] {
        try withSerializedDatabaseAccess {
            let normalizedTerm = term.lowercased()
            let containsPattern = "%\(normalizedTerm)%"
            let sql = """
            SELECT s.entry_id
            FROM glosses g
            JOIN senses s ON s.id = g.sense_id
            WHERE LOWER(g.gloss) LIKE ?1
            GROUP BY s.entry_id
            ORDER BY s.entry_id ASC
            LIMIT ?2
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            try bindText(containsPattern, index: 1, statement: statement)
            try bindInt64(Int64(limit), index: 2, statement: statement)

            return try stepRows(statement: statement) { stmt in
                Int64(sqlite3_column_int64(stmt, 0))
            }
        }
    }
}

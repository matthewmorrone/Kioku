import Foundation
import SQLite3

// Enrichment query surface — pitch accent, example sentences, sense metadata, and KANJIDIC2 lookups.
extension DictionaryStore {

    // Fetches pitch accent records for a word+kana pair from the UniDic-derived pitch_accent table.
    // The pitch_accent table stores readings in katakana (UniDic convention), so the incoming
    // kana is converted to katakana before querying to match regardless of script.
    nonisolated public func fetchPitchAccent(word: String, kana: String) throws -> [PitchAccent] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT word, kana, kind, accent, morae
            FROM pitch_accent
            WHERE word = ?1 AND kana = ?2
            ORDER BY id ASC
            """

            // Convert hiragana to katakana so the query matches the UniDic-derived table.
            let katakana = kana.applyingTransform(.hiraganaToKatakana, reverse: false) ?? kana

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindText(word, index: 1, statement: statement)
            try bindText(katakana, index: 2, statement: statement)

            let rows: [PitchAccent] = try stepRows(statement: statement) { stmt in
                guard
                    let wordPointer = sqlite3_column_text(stmt, 0),
                    let kanaPointer = sqlite3_column_text(stmt, 1)
                else { return nil }

                // accent and morae are NOT NULL in the schema; treat a NULL as data corruption.
                guard
                    sqlite3_column_type(stmt, 3) != SQLITE_NULL,
                    sqlite3_column_type(stmt, 4) != SQLITE_NULL
                else {
                    throw DictionarySQLiteError.corruptRow(
                        message: "NULL accent or morae in pitch_accent for word=\(word), kana=\(kana)"
                    )
                }

                return PitchAccent(
                    word: String(cString: wordPointer),
                    kana: String(cString: kanaPointer),
                    kind: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                    accent: Int(sqlite3_column_int(stmt, 3)),
                    morae: Int(sqlite3_column_int(stmt, 4))
                )
            }

            // UniDic stores one row per POS category, so a reading with a single accent pattern
            // appears several times (e.g. なる/ナル: 固有名詞・非自立可能・一般 all atamadaka=1).
            // PitchAccentView draws purely from (accent, morae) and never shows `kind`, so those
            // rows render as identical diagrams. Collapse them by what's actually drawn, keeping
            // first-seen order — leaving なる with its two real patterns (頭高 + 平板).
            var seen = Set<String>()
            return rows.filter { seen.insert("\($0.accent)|\($0.morae)").inserted }
        }
    }

    // Fetches example sentence pairs matching any of the given search terms.
    // Searches for the surface first, then any additional terms (e.g. lemma kanji forms)
    // so results favor the exact surface while still finding sentences that use the base form.
    // Uses FTS5 for fast substring search, deduplicates on Japanese text, sorted shortest first.
    nonisolated public func fetchSentencePairs(terms: [String]) throws -> [SentencePair] {
        // Deduplicate and filter empty terms while preserving priority order.
        var uniqueTerms: [String] = []
        var seen = Set<String>()
        for term in terms where term.isEmpty == false && seen.insert(term).inserted {
            uniqueTerms.append(term)
        }
        guard uniqueTerms.isEmpty == false else { return [] }

        return try withSerializedDatabaseAccess {
            let sql = """
            SELECT sp.japanese, sp.english
            FROM sentence_pairs sp
            JOIN sentence_pairs_fts ON sentence_pairs_fts.rowid = sp.rowid
            WHERE sentence_pairs_fts MATCH ?1
            ORDER BY LENGTH(sp.japanese) ASC
            """

            var allPairs: [SentencePair] = []

            // Query each term in priority order so surface matches come first.
            for term in uniqueTerms {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }

                try prepare(sql: sql, statement: &statement)
                // FTS5 phrase search wraps the term in quotes for exact substring matching.
                try bindText("\"\(term)\"", index: 1, statement: statement)

                let rows = try stepRows(statement: statement) { stmt -> SentencePair? in
                    guard
                        let japanesePointer = sqlite3_column_text(stmt, 0),
                        let englishPointer = sqlite3_column_text(stmt, 1)
                    else { return nil }

                    return SentencePair(
                        japanese: String(cString: japanesePointer),
                        english: String(cString: englishPointer)
                    )
                }

                allPairs.append(contentsOf: rows)
            }

            // Normalized dedup across all terms — collapses Tatoeba near-duplicates
            // (trailing 。, wrapping 「」, whitespace) that exact-string equality
            // would miss. Preserves order so the priority-ordered surface→lemma walk
            // above still wins the first slot for the user-visible example list.
            return SentencePairDedup.dedupe(allPairs)
        }
    }

    // Free-form sentence search across the whole Tatoeba corpus.
    // Treats the query as a single FTS5 phrase; returns up to `limit` shortest matches.
    // Distinct from `fetchSentencePairs(terms:)` because that variant filters to lemma-specific
    // priority terms for the per-entry detail view; this one is for browsing.
    nonisolated public func searchSentences(query: String, limit: Int = 200) throws -> [SentencePair] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        // Escape any embedded double-quotes so they don't break the FTS5 phrase.
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")

        return try withSerializedDatabaseAccess {
            let sql = """
            SELECT sp.japanese, sp.english
            FROM sentence_pairs sp
            JOIN sentence_pairs_fts ON sentence_pairs_fts.rowid = sp.rowid
            WHERE sentence_pairs_fts MATCH ?1
            ORDER BY LENGTH(sp.japanese) ASC
            LIMIT ?2
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindText("\"\(escaped)\"", index: 1, statement: statement)
            try bindInt64(Int64(limit), index: 2, statement: statement)

            let rows = try stepRows(statement: statement) { stmt -> SentencePair? in
                guard
                    let japanesePointer = sqlite3_column_text(stmt, 0),
                    let englishPointer = sqlite3_column_text(stmt, 1)
                else { return nil }
                return SentencePair(
                    japanese: String(cString: japanesePointer),
                    english: String(cString: englishPointer)
                )
            }
            // Free-form search has no priority loop to dedup across, but the corpus
            // itself contains punctuation/quote near-duplicates — same normalized
            // dedup as fetchSentencePairs.
            return SentencePairDedup.dedupe(rows)
        }
    }

    // Convenience overload that searches for a single surface string.
    nonisolated public func fetchSentencePairs(surface: String) throws -> [SentencePair] {
        try fetchSentencePairs(terms: [surface])
    }

    // Fetches sense-level stagk/stagr application restrictions for one entry.
    // Each restriction identifies which kanji or kana form a particular sense applies to.
    nonisolated public func fetchSenseRestrictions(entryID: Int64) throws -> [SenseRestriction] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT s.order_index, sr.type, sr.value
            FROM sense_restrictions sr
            JOIN senses s ON s.id = sr.sense_id
            WHERE s.entry_id = ?1
            ORDER BY s.order_index ASC, sr.type ASC, sr.value ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindInt64(entryID, index: 1, statement: statement)

            return try stepRows(statement: statement) { stmt in
                let senseOrderIndex = Int(sqlite3_column_int(stmt, 0))
                guard
                    let typeStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                    let type = SenseRestrictionKind(rawValue: typeStr),
                    let valuePointer = sqlite3_column_text(stmt, 2)
                else { return nil }

                return SenseRestriction(
                    senseOrderIndex: senseOrderIndex,
                    type: type,
                    value: String(cString: valuePointer)
                )
            }
        }
    }

    // Fetches sense-level xref/ant cross-reference and antonym records for one entry.
    public func fetchSenseReferences(entryID: Int64) throws -> [SenseReference] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT s.order_index, sr.type, sr.target
            FROM sense_references sr
            JOIN senses s ON s.id = sr.sense_id
            WHERE s.entry_id = ?1
            ORDER BY s.order_index ASC, sr.type ASC, sr.target ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindInt64(entryID, index: 1, statement: statement)

            return try stepRows(statement: statement) { stmt in
                let senseOrderIndex = Int(sqlite3_column_int(stmt, 0))
                guard
                    let typeStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                    let type = SenseReferenceKind(rawValue: typeStr),
                    let targetPointer = sqlite3_column_text(stmt, 2)
                else { return nil }

                return SenseReference(
                    senseOrderIndex: senseOrderIndex,
                    type: type,
                    target: String(cString: targetPointer)
                )
            }
        }
    }

    // Fetches lsource loanword-origin records for one entry.
    public func fetchLoanwordSources(entryID: Int64) throws -> [LoanwordSource] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT s.order_index, ls.lang, ls.ls_wasei, ls.ls_type, ls.content
            FROM lsource ls
            JOIN senses s ON s.id = ls.sense_id
            WHERE s.entry_id = ?1
            ORDER BY s.order_index ASC, ls.id ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindInt64(entryID, index: 1, statement: statement)

            return try stepRows(statement: statement) { stmt in
                let senseOrderIndex = Int(sqlite3_column_int(stmt, 0))
                guard let langPointer = sqlite3_column_text(stmt, 1) else { return nil }

                let wasei = sqlite3_column_int(stmt, 2) != 0
                // Fall back to .part when the column is NULL or contains an unrecognised value.
                let lsTypeStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "part"
                let lsType = LoanwordSourceType(rawValue: lsTypeStr) ?? .part
                let content = sqlite3_column_text(stmt, 4).map { String(cString: $0) }

                return LoanwordSource(
                    senseOrderIndex: senseOrderIndex,
                    lang: String(cString: langPointer),
                    wasei: wasei,
                    lsType: lsType,
                    content: content
                )
            }
        }
    }

    // Fetches KANJIDIC2 metadata for one kanji literal — grade, strokes, JLPT level, on/kun readings, and English meanings.
    // Returns nil when the character is absent from the kanji_characters table.
    // `nonisolated` so the Words tab's off-main `searchKanji(...)` can call it from
    // a detached Task without an MainActor hop per literal — every SQL call still
    // serializes through `withSerializedDatabaseAccess`.
    nonisolated func fetchKanjiInfo(for literal: String) throws -> KanjiInfo? {
        try withSerializedDatabaseAccess {
            let charSQL = """
            SELECT grade, stroke_count, jlpt_level, radical, freq_mainichi
            FROM kanji_characters
            WHERE literal = ?1
            LIMIT 1
            """

            var charStatement: OpaquePointer?
            defer { sqlite3_finalize(charStatement) }
            try prepare(sql: charSQL, statement: &charStatement)
            try bindText(literal, index: 1, statement: charStatement)

            let charStep = sqlite3_step(charStatement)
            guard charStep == SQLITE_ROW else {
                return nil
            }

            let grade = sqlite3_column_type(charStatement, 0) != SQLITE_NULL
                ? Int(sqlite3_column_int(charStatement, 0)) : nil
            let strokeCount = sqlite3_column_type(charStatement, 1) != SQLITE_NULL
                ? Int(sqlite3_column_int(charStatement, 1)) : nil
            let jlptLevel = sqlite3_column_type(charStatement, 2) != SQLITE_NULL
                ? Int(sqlite3_column_int(charStatement, 2)) : nil
            let radical = sqlite3_column_type(charStatement, 3) != SQLITE_NULL
                ? Int(sqlite3_column_int(charStatement, 3)) : nil
            let freqMainichi = sqlite3_column_type(charStatement, 4) != SQLITE_NULL
                ? Int(sqlite3_column_int(charStatement, 4)) : nil

            let readingsSQL = """
            SELECT kr.reading, kr.type
            FROM kanji_readings kr
            JOIN kanji_characters kc ON kc.id = kr.kanji_id
            WHERE kc.literal = ?1 AND kr.type IN ('on', 'kun')
            ORDER BY kr.type DESC, kr.id ASC
            """

            var readingsStatement: OpaquePointer?
            defer { sqlite3_finalize(readingsStatement) }
            try prepare(sql: readingsSQL, statement: &readingsStatement)
            try bindText(literal, index: 1, statement: readingsStatement)

            let readingPairs = try stepRows(statement: readingsStatement) { stmt -> (String, String)? in
                guard
                    let readingPointer = sqlite3_column_text(stmt, 0),
                    let typePointer = sqlite3_column_text(stmt, 1)
                else { return nil }
                return (String(cString: readingPointer), String(cString: typePointer))
            }

            var onReadings: [String] = []
            var kunReadings: [String] = []
            for (reading, type) in readingPairs {
                if type == "on" { onReadings.append(reading) } else { kunReadings.append(reading) }
            }

            let meaningsSQL = """
            SELECT km.meaning
            FROM kanji_meanings km
            JOIN kanji_characters kc ON kc.id = km.kanji_id
            WHERE kc.literal = ?1 AND km.lang = 'en'
            ORDER BY km.id ASC
            """

            var meaningsStatement: OpaquePointer?
            defer { sqlite3_finalize(meaningsStatement) }
            try prepare(sql: meaningsSQL, statement: &meaningsStatement)
            try bindText(literal, index: 1, statement: meaningsStatement)

            let meanings = try stepRows(statement: meaningsStatement) { stmt -> String? in
                sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            }

            return KanjiInfo(
                literal: literal,
                grade: grade,
                strokeCount: strokeCount,
                jlptLevel: jlptLevel,
                radical: radical,
                freqMainichi: freqMainichi,
                onReadings: onReadings,
                kunReadings: kunReadings,
                meanings: meanings
            )
        }
    }

    // Builds the single-kanji → preferred-reading map used as the last-resort furigana source
    // (see KanjiReadingFallbackMap). One scan over kanji_readings for every single-character
    // literal, kun readings preferred over on (kun tends to be the natural standalone reading —
    // e.g. 眩 → まぶ from まぶ.しい, which also happens to be correct for 眩しげ). The reading is
    // cleaned into plain furigana hiragana:
    //   • kun readings carry okurigana after a "." (まぶ.しい) and prefix/suffix "-" markers,
    //     both of which are stripped so only the on-the-kanji stem remains,
    //   • on readings are stored in katakana and converted to hiragana.
    // Candidates that don't reduce to pure hiragana (rare KANJIDIC artifacts) are skipped, and the
    // first valid reading per literal wins. Returns character-keyed entries ready to wrap in a map.
    nonisolated func fetchKanjiReadingFallbackMap() throws -> [Character: String] {
        try withSerializedDatabaseAccess {
            // length(literal) = 1 keeps multi-codepoint literals out so keys stay single Characters.
            // The CASE orders kun before on; kr.id breaks ties so the primary reading comes first.
            let sql = """
            SELECT kc.literal, kr.reading, kr.type
            FROM kanji_readings kr
            JOIN kanji_characters kc ON kc.id = kr.kanji_id
            WHERE kr.type IN ('on', 'kun') AND length(kc.literal) = 1
            ORDER BY kc.literal ASC, CASE kr.type WHEN 'kun' THEN 0 ELSE 1 END ASC, kr.id ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)

            let rows = try stepRows(statement: statement) { stmt -> (String, String, String)? in
                guard
                    let literalPointer = sqlite3_column_text(stmt, 0),
                    let readingPointer = sqlite3_column_text(stmt, 1),
                    let typePointer = sqlite3_column_text(stmt, 2)
                else { return nil }
                return (String(cString: literalPointer), String(cString: readingPointer), String(cString: typePointer))
            }

            var map: [Character: String] = [:]
            for (literal, reading, _) in rows {
                guard let kanji = literal.first, literal.count == 1 else { continue }
                // Rows are ordered with the preferred reading first, so once a literal has an
                // entry we keep it and skip the remaining (lower-priority) readings.
                if map[kanji] != nil { continue }
                guard let cleaned = Self.cleanedKanjiReadingForFurigana(reading) else { continue }
                map[kanji] = cleaned
            }
            return map
        }
    }

    // Reduces a raw KANJIDIC2 reading to a furigana-ready hiragana stem, or nil if nothing usable
    // remains. Drops okurigana (everything from the first ".") and prefix/suffix "-" markers, then
    // converts katakana (on'yomi) to hiragana; returns nil when the result isn't pure hiragana.
    nonisolated private static func cleanedKanjiReadingForFurigana(_ reading: String) -> String? {
        var stem = reading
        if let dot = stem.firstIndex(of: ".") {
            stem = String(stem[..<dot])
        }
        stem = stem.replacingOccurrences(of: "-", with: "")
        guard stem.isEmpty == false else { return nil }
        let hiragana = KanaNormalizer.katakanaToHiragana(stem)
        guard ScriptClassifier.isPureHiragana(hiragana) else { return nil }
        return hiragana
    }

    // Searches KANJIDIC2 for kanji that match the user's query, returning frequency-
    // ranked KanjiInfo records. Three signals (in priority order):
    //   1. Direct kanji literals present in the query — `火` matches 火.
    //   2. Exact English meaning — `rain` matches 雨 (whose meanings contain "rain").
    //   3. Exact on/kun reading — `ひ` (or romaji "hi") matches 日, 火, etc.
    // Results from earlier passes outrank later ones; within a pass, lower
    // freq_mainichi wins (1 = most common). Duplicates across passes are deduped.
    // Used by the Words tab search to surface kanji rows at the top of results.
    nonisolated func searchKanji(query: String, kanaQuery: String?, limit: Int = 6) throws -> [KanjiInfo] {
        var ordered: [String] = []
        var seen: Set<String> = []

        // Pass 1 — direct kanji literals in the query. These are explicit user intent
        // (they typed the kanji), so all are included regardless of frequency.
        for char in query {
            let scalars = char.unicodeScalars
            guard scalars.contains(where: ScriptClassifier.isKanjiScalar) else { continue }
            let literal = String(char)
            if seen.insert(literal).inserted { ordered.append(literal) }
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let queryHasKana = trimmed.unicodeScalars.contains(where: ScriptClassifier.isKanaScalar)

        // Pass 2 — exact English meaning. Capped at the single most common match;
        // a query like "rain" should surface 雨 and nothing else, not 雨 + 霖 + 雷.
        if ordered.isEmpty, lowered.isEmpty == false,
           ScriptClassifier.containsKanji(trimmed) == false,
           queryHasKana == false {
            for literal in try searchKanjiByMeaning(meaning: lowered, limit: 1) {
                if seen.insert(literal).inserted { ordered.append(literal) }
            }
        }

        // Pass 3 — exact kana reading (typed kana, or romaji→kana). Same single-top
        // policy: "ひ" → 日 (most common kanji with that reading), not 日 + 火 + 比 + …
        if ordered.isEmpty {
            let readingCandidates: [String] = [
                trimmed.isEmpty ? nil : trimmed,
                kanaQuery.flatMap { $0.isEmpty ? nil : $0 }
            ].compactMap { $0 }
            for reading in readingCandidates {
                guard reading.unicodeScalars.contains(where: ScriptClassifier.isKanaScalar) else { continue }
                let katakana = reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading
                let hiragana = reading.applyingTransform(.hiraganaToKatakana, reverse: true) ?? reading
                for literal in try searchKanjiByReading(readings: [katakana, hiragana], limit: 1) {
                    if seen.insert(literal).inserted { ordered.append(literal) }
                }
                if ordered.isEmpty == false { break }
            }
        }

        // Hydrate each literal into a full KanjiInfo, then sort the final list by
        // Mainichi-newspaper frequency (1 = most common; nils sink to the bottom).
        // Sort happens after fetch so multi-kanji literal queries like 火曜日 surface
        // common chars first instead of query order.
        var results: [KanjiInfo] = []
        for literal in ordered {
            if let info = try fetchKanjiInfo(for: literal) {
                results.append(info)
            }
        }
        results.sort { lhs, rhs in
            switch (lhs.freqMainichi, rhs.freqMainichi) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return false
            }
        }
        return Array(results.prefix(limit))
    }

    // Returns kanji literals whose English meaning exactly matches `meaning`
    // (case-insensitive), ordered by Mainichi-newspaper frequency. Exact match
    // keeps results relevant; LIKE % …% would surface every kanji whose meaning
    // contains the substring ("ear" → 100+ matches).
    private nonisolated func searchKanjiByMeaning(meaning: String, limit: Int) throws -> [String] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT DISTINCT kc.literal
            FROM kanji_characters kc
            JOIN kanji_meanings km ON km.kanji_id = kc.id
            WHERE km.lang = 'en' AND LOWER(km.meaning) = ?1
            ORDER BY (kc.freq_mainichi IS NULL), kc.freq_mainichi ASC
            LIMIT ?2
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            try bindText(meaning, index: 1, statement: statement)
            sqlite3_bind_int(statement, 2, Int32(limit))
            return try stepRows(statement: statement) { stmt -> String? in
                sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            }
        }
    }

    // Returns kanji literals whose on or kun reading exactly matches any of the
    // supplied reading variants, ordered by frequency. Variant list lets the caller
    // pass both katakana and hiragana forms — KANJIDIC2 stores on'yomi in katakana
    // and kun'yomi in hiragana, and the user types either.
    private nonisolated func searchKanjiByReading(readings: [String], limit: Int) throws -> [String] {
        guard readings.isEmpty == false else { return [] }
        let deduped = Array(Set(readings))
        let placeholders = deduped.map { _ in "?" }.joined(separator: ", ")
        return try withSerializedDatabaseAccess {
            let sql = """
            SELECT DISTINCT kc.literal
            FROM kanji_characters kc
            JOIN kanji_readings kr ON kr.kanji_id = kc.id
            WHERE kr.reading IN (\(placeholders))
            ORDER BY (kc.freq_mainichi IS NULL), kc.freq_mainichi ASC
            LIMIT ?
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            for (idx, reading) in deduped.enumerated() {
                try bindText(reading, index: Int32(idx + 1), statement: statement)
            }
            sqlite3_bind_int(statement, Int32(deduped.count + 1), Int32(limit))
            return try stepRows(statement: statement) { stmt -> String? in
                sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            }
        }
    }

    // Returns the most-frequent kanji from KANJIDIC2 (by Mainichi-newspaper
    // frequency rank, 1 = most common) as fully-hydrated KanjiInfo records up
    // to `limit`. Used by Browse Kanji by Frequency. Returns at most the
    // ~2500 kanji that ship with a Mainichi rank — kanji with no rank are
    // excluded entirely since "most frequent" only makes sense for those.
    nonisolated func fetchTopFrequencyKanji(limit: Int) throws -> [KanjiInfo] {
        let literals = try withSerializedDatabaseAccess { () -> [String] in
            let sql = """
            SELECT literal
            FROM kanji_characters
            WHERE freq_mainichi IS NOT NULL
            ORDER BY freq_mainichi ASC
            LIMIT ?1
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            sqlite3_bind_int(statement, 1, Int32(limit))
            return try stepRows(statement: statement) { stmt -> String? in
                sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            }
        }
        var results: [KanjiInfo] = []
        results.reserveCapacity(literals.count)
        for literal in literals {
            if let info = try fetchKanjiInfo(for: literal) { results.append(info) }
        }
        return results
    }
}

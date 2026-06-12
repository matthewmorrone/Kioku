import Foundation
import SQLite3

// Per-row SQLite fetch helpers for DictionaryStore: assembling matched entry headers
// (with frequency data) and the per-entry kanji forms, kana forms, sense restrictions,
// and senses. Extracted from DictionaryStore so the primary file stays under the
// line-count invariant. Methods are internal (not private) so the lookup methods in the
// primary file can call them across the file boundary.
extension DictionaryStore {
    // Fetches entry headers with frequency data, ordered by JPDB rank then sense order.
    nonisolated func fetchMatchedEntries(surface: String, matchKana: Bool, matchKanji: Bool) throws -> [(entryID: Int64, jpdbRank: Int?, wordfreqZipf: Double?)] {
        guard matchKana || matchKanji else {
            return []
        }

        let whereClause: String
        // Constrain the frequency join to only consider readings that match the looked-up surface.
        // Without this, an entry like 鑑 (かがみ=rare, かんがみる=common) would sort by its best
        // rank across ALL readings, misrepresenting the frequency of the matched reading.
        let frequencyJoin: String
        if matchKana && matchKanji {
            // Drive from the text indexes (idx_kanji_text / idx_kana_text) instead of an
            // EXISTS correlated to `e`. An EXISTS-in-WHERE makes `entries` the driving table —
            // SQLite scans all ~215k rows and probes each. The `e.id IN (… WHERE text=?1)` form
            // makes the text index the driver: seek the handful of matching surface rows, then
            // PK-join back to `entries`. Same result set, ~1000× fewer rows touched.
            whereClause = """
            e.id IN (
                SELECT entry_id FROM kanji WHERE text = ?1
                UNION
                SELECT entry_id FROM kana_forms WHERE text = ?1
            )
            """
            frequencyJoin = """
            LEFT JOIN word_frequency wf ON wf.entry_id = e.id
                AND (EXISTS (SELECT 1 FROM kana_forms kf2 WHERE kf2.id = wf.kana_id AND kf2.text = ?1)
                  OR EXISTS (SELECT 1 FROM kanji kj2 WHERE kj2.id = wf.kanji_id AND kj2.text = ?1))
            """
        } else if matchKana {
            whereClause = "e.id IN (SELECT entry_id FROM kana_forms WHERE text = ?1)"
            frequencyJoin = """
            LEFT JOIN word_frequency wf ON wf.entry_id = e.id
                AND EXISTS (SELECT 1 FROM kana_forms kf2 WHERE kf2.id = wf.kana_id AND kf2.text = ?1)
            """
        } else {
            whereClause = "e.id IN (SELECT entry_id FROM kanji WHERE text = ?1)"
            frequencyJoin = """
            LEFT JOIN word_frequency wf ON wf.entry_id = e.id
                AND EXISTS (SELECT 1 FROM kanji kj2 WHERE kj2.id = wf.kanji_id AND kj2.text = ?1)
            """
        }

        // Ranking strategy for a kana surface lookup (matchKana && !matchKanji):
        //   1. Kana-only entries first. An entry whose primary form IS the queried kana
        //      (no kanji_forms rows) is by definition a more exact match than an entry
        //      that merely lists that kana as a reading of a kanji headword. Particles
        //      (の, は, が), interjections, and sound effects always live in kana-only
        //      entries; without this tier they get buried under whatever kanji shares the
        //      reading (eg tapping は returns 派 "group; faction" instead of the topic
        //      particle, because wordfreq has no row for the particle so its zipf-based
        //      pseudo-rank collapses to the catch-all bucket).
        //   2. Within each tier, sort by JPDB rank, then a zipf-derived pseudo-rank for
        //      kana-only entries that lack JPDB data, then by sense order and entry id.
        // For matchKanji-only the WHERE clause already excludes kana-only entries, so
        // the primary tier is a no-op there; for matchKana && matchKanji (kanji surface
        // lookups), kana-only entries can't match a kanji surface either, so again a
        // no-op. Result: the tier only changes ordering for the kana-surface case where
        // the homophone collision actually occurs.
        //
        // Tier 1 (POS boost) is gated to `matchKana && !matchKanji` only. Particles like
        // が / の have archaic kanji forms (我, 乃, 之), so when the user explicitly looks
        // up a kanji surface — tap on 我 in text or search for "我" directly — the WHERE
        // clause matches both the pronoun 我 (われ) AND the particle が entry. Without the
        // gate, the particle entry's `prt` POS tag would promote it ahead of the actual
        // kanji-word match for surfaces the user clearly intended in their kanji form.
        let posBoostTier: String
        if matchKana && !matchKanji {
            posBoostTier = """
                -- Tier 1: particle / functional-word / demonstrative entries first for kana
                -- surface lookups. POS tags that qualify:
                --   prt  (particle: は, が, を, …)
                --   cop  (copula: だ)
                --   aux  (auxiliary: ない, られる, …; also aux-v, aux-adj prefixes)
                --   adj-pn (pre-noun adjectival: この, その, あの, どの, etc.)
                -- adj-pn was added after a tap on その resolved to 園 ("garden; orchard; park")
                -- because 園 has kana form その and adj-pn wasn't yet in the boost list. The
                -- demonstrative その entry is kana-only (has_kanji=0) and would normally win
                -- via the has_kanji tier — but only when the kanji entry doesn't share the
                -- same reading. JMdict has many such collisions (この vs 此, その vs 園, あの
                -- vs 彼の, etc.), and the user always wants the demonstrative.
                -- ',?' regex-ish matching via LIKE since pos is a comma-joined tag list.
                CASE WHEN EXISTS (
                    SELECT 1 FROM senses s2 WHERE s2.entry_id = e.id
                    AND (s2.pos = 'prt' OR s2.pos LIKE 'prt,%' OR s2.pos LIKE '%,prt,%' OR s2.pos LIKE '%,prt'
                      OR s2.pos = 'cop' OR s2.pos LIKE 'cop,%' OR s2.pos LIKE '%,cop,%' OR s2.pos LIKE '%,cop'
                      OR s2.pos = 'aux' OR s2.pos LIKE 'aux,%' OR s2.pos LIKE '%,aux,%' OR s2.pos LIKE '%,aux'
                      OR s2.pos LIKE 'aux-%' OR s2.pos LIKE '%,aux-%'
                      OR s2.pos = 'adj-pn' OR s2.pos LIKE 'adj-pn,%' OR s2.pos LIKE '%,adj-pn,%' OR s2.pos LIKE '%,adj-pn')
                ) THEN 0 ELSE 1 END ASC,
            """
        } else {
            posBoostTier = ""
        }
        let sql = """
        SELECT e.id,
               MIN(wf.jpdb_rank) AS best_jpdb,
               MAX(wf.wordfreq_zipf) AS best_zipf,
               EXISTS (SELECT 1 FROM kanji k WHERE k.entry_id = e.id) AS has_kanji,
               COALESCE(MIN(s.order_index), \(FrequencySQL.noSenseSort)) AS min_sense
        FROM entries e
        \(frequencyJoin)
        LEFT JOIN senses s ON s.entry_id = e.id
        WHERE \(whereClause)
        GROUP BY e.id
        ORDER BY
            \(posBoostTier)
            -- Tier 2: kana-only entries (no kanji forms) before kanji-bearing ones. Catches
            -- truly kana-only headwords (interjections, sound effects, casual kana usages)
            -- and is a no-op for kanji-surface lookups (where kana-only entries can't match
            -- anyway). For matchKanji-only the WHERE clause already excludes kana-only.
            CASE WHEN EXISTS (SELECT 1 FROM kanji k WHERE k.entry_id = e.id) THEN 1 ELSE 0 END ASC,
            -- Tier 3: effective rank — JPDB rank if present, else a pseudo-rank derived
            -- from the wordfreq Zipf score (general-corpus log frequency). Applied
            -- uniformly so a non-JPDB-ranked common word (e.g. a kanji entry JPDB didn't
            -- catalog) can still outrank an obscure JPDB-ranked homophone instead of
            -- crashing to 9999999. Zipf 7+ ≈ top-30 word, 6+ ≈ top-1k, etc.; bucket
            -- boundaries are deliberately wider than JPDB's so a high-confidence corpus
            -- signal beats a low-confidence JPDB ranking.
            \(FrequencySQL.effectiveRank(jpdbExpr: "MIN(wf.jpdb_rank)", zipfExpr: "MAX(wf.wordfreq_zipf)")) ASC,
            min_sense ASC,
            e.id ASC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        try bindText(surface, index: 1, statement: statement)

        var items: [(entryID: Int64, jpdbRank: Int?, wordfreqZipf: Double?)] = []

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            let entryID = sqlite3_column_int64(statement, 0)
            let jpdbRank = sqlite3_column_type(statement, 1) != SQLITE_NULL
                ? Int(sqlite3_column_int(statement, 1))
                : nil
            let wordfreqZipf = sqlite3_column_type(statement, 2) != SQLITE_NULL
                ? sqlite3_column_double(statement, 2)
                : nil
            items.append((entryID: entryID, jpdbRank: jpdbRank, wordfreqZipf: wordfreqZipf))

            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        return items
    }

    // Fetches one entry header by ID so callers can rebuild full entry payloads deterministically.
    nonisolated func fetchEntryHeader(entryID: Int64) throws -> (entryID: Int64, jpdbRank: Int?, wordfreqZipf: Double?)? {
        let sql = """
        SELECT e.id, MIN(wf.jpdb_rank), MAX(wf.wordfreq_zipf)
        FROM entries e
        LEFT JOIN word_frequency wf ON wf.entry_id = e.id
        WHERE e.id = ?1
        GROUP BY e.id
        LIMIT 1
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        try bindInt64(entryID, index: 1, statement: statement)

        let stepCode = sqlite3_step(statement)
        if stepCode == SQLITE_DONE {
            return nil
        }

        guard stepCode == SQLITE_ROW else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        let resolvedEntryID = sqlite3_column_int64(statement, 0)
        let jpdbRank = sqlite3_column_type(statement, 1) != SQLITE_NULL
            ? Int(sqlite3_column_int(statement, 1))
            : nil
        let wordfreqZipf = sqlite3_column_type(statement, 2) != SQLITE_NULL
            ? sqlite3_column_double(statement, 2)
            : nil

        let completionCode = sqlite3_step(statement)
        guard completionCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        return (entryID: resolvedEntryID, jpdbRank: jpdbRank, wordfreqZipf: wordfreqZipf)
    }

    // Fetches ordered kanji forms with priority and ke_inf info tags for one entry.
    nonisolated func fetchKanjiForms(entryID: Int64) throws -> [KanjiForm] {
        // ORDER BY id preserves JMdict insertion order; alphabetic ordering
        // breaks "first form is primary reading" semantics that callers rely on
        // (e.g. preferredKana selecting the JMdict-canonical reading).
        let sql = """
        SELECT text, priority, info
        FROM kanji
        WHERE entry_id = ?1
        ORDER BY id ASC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        try bindInt64(entryID, index: 1, statement: statement)

        var items: [KanjiForm] = []
        var seenTexts = Set<String>()

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            guard let textPointer = sqlite3_column_text(statement, 0) else {
                stepCode = sqlite3_step(statement)
                continue
            }

            let text = String(cString: textPointer)
            // Keep first-seen order to mirror SQL ordering while avoiding duplicates.
            if seenTexts.insert(text).inserted {
                let priority = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let info = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                items.append(KanjiForm(text: text, priority: priority, info: info))
            }

            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        return items
    }

    // Fetches ordered kana forms with priority, re_inf info tags, and nokanji flag for one entry.
    // ORDER BY id preserves JMdict insertion order; alphabetic ordering breaks
    // the "first kana form is the primary reading" contract that preferredKana
    // and other display sites depend on.
    nonisolated func fetchKanaForms(entryID: Int64) throws -> [KanaForm] {
        let sql = """
        SELECT text, priority, info, re_nokanji
        FROM kana_forms
        WHERE entry_id = ?1
        ORDER BY id ASC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        try bindInt64(entryID, index: 1, statement: statement)

        var items: [KanaForm] = []
        var seenTexts = Set<String>()

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            guard let textPointer = sqlite3_column_text(statement, 0) else {
                stepCode = sqlite3_step(statement)
                continue
            }

            let text = String(cString: textPointer)
            // Keep first-seen order to mirror SQL ordering while avoiding duplicates.
            if seenTexts.insert(text).inserted {
                let priority = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let info = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                let nokanji = sqlite3_column_int(statement, 3) != 0
                items.append(KanaForm(text: text, priority: priority, info: info, nokanji: nokanji))
            }

            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        return items
    }

    // Fetches sense-level kanji/kana restrictions for one entry, grouped by sense_id.
    // Returns a map of sense_id → (stagk values, stagr values). Senses without restrictions
    // are absent from the map and treated as "applies to all forms" at the call site.
    nonisolated func fetchSenseRestrictionMap(entryID: Int64) throws -> [Int64: (kanji: [String], readings: [String])] {
        let sql = """
        SELECT sr.sense_id, sr.type, sr.value
        FROM sense_restrictions sr
        JOIN senses s ON s.id = sr.sense_id
        WHERE s.entry_id = ?1
        ORDER BY sr.id ASC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(sql: sql, statement: &statement)
        try bindInt64(entryID, index: 1, statement: statement)

        var map: [Int64: (kanji: [String], readings: [String])] = [:]
        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            let senseID = sqlite3_column_int64(statement, 0)
            let type = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let value = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            if let type, let value {
                var entry = map[senseID] ?? (kanji: [], readings: [])
                switch type {
                case "stagk": entry.kanji.append(value)
                case "stagr": entry.readings.append(value)
                default: break
                }
                map[senseID] = entry
            }
            stepCode = sqlite3_step(statement)
        }
        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }
        return map
    }

    // Fetches senses and ordered glosses for one entry, including misc, field, and dialect tags.
    nonisolated func fetchSenses(entryID: Int64) throws -> [DictionaryEntrySense] {
        let sql = """
        SELECT s.id, s.pos, s.misc, s.field, s.dialect, s.info, g.gloss
        FROM senses s
        LEFT JOIN glosses g ON g.sense_id = s.id
        WHERE s.entry_id = ?1
        ORDER BY s.order_index ASC, g.order_index ASC, g.id ASC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        try bindInt64(entryID, index: 1, statement: statement)

        // Pre-fetch reading/kanji restrictions so each sense can be tagged at construction time.
        // Senses with no entry in the map have no restrictions → apply to every form (JMdict default).
        let restrictions = try fetchSenseRestrictionMap(entryID: entryID)

        var senses: [DictionaryEntrySense] = []
        var currentSenseID: Int64?
        var currentPOS: String?
        var currentMisc: String?
        var currentField: String?
        var currentDialect: String?
        var currentInfo: String?
        var currentGlosses: [String] = []

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {

            let senseID = sqlite3_column_int64(statement, 0)
            let pos = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let misc = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let field = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let dialect = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let info = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            let gloss = sqlite3_column_text(statement, 6).map { String(cString: $0) }

            if currentSenseID != senseID {
                // Flush the previous sense before starting the next grouped row set.
                if let id = currentSenseID {
                    let r = restrictions[id]
                    senses.append(DictionaryEntrySense(
                        senseID: id,
                        pos: currentPOS,
                        misc: currentMisc,
                        field: currentField,
                        dialect: currentDialect,
                        info: currentInfo,
                        glosses: currentGlosses,
                        applicableKanji: r?.kanji ?? [],
                        applicableReadings: r?.readings ?? []
                    ))
                }
                currentSenseID = senseID
                currentPOS = pos
                currentMisc = misc
                currentField = field
                currentDialect = dialect
                currentInfo = info
                currentGlosses = []
            }

            if let gloss, !gloss.isEmpty {
                currentGlosses.append(gloss)
            }

            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        // Flush the final grouped sense after stepping completes.
        if let id = currentSenseID {
            let r = restrictions[id]
            senses.append(DictionaryEntrySense(
                senseID: id,
                pos: currentPOS,
                misc: currentMisc,
                field: currentField,
                dialect: currentDialect,
                info: currentInfo,
                glosses: currentGlosses,
                applicableKanji: r?.kanji ?? [],
                applicableReadings: r?.readings ?? []
            ))
        }

        return senses
    }
}

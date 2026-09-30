import Foundation
import SQLite3

// Frequency query surface — builds the unified surface reading map used by segmentation, furigana, and frequency display.
extension DictionaryStore {

    // Fetches one page of dictionary entries by frequency rank, materialized for browse-view display.
    // Entries with multiple readings collapse to their best-ranked reading (MIN(frequency_rank)).
    nonisolated func fetchTopFrequencyEntries(limit: Int, offset: Int = 0) throws -> [DictionaryEntry] {
        let entryIDs = try fetchTopFrequencyEntryIDs(limit: limit, offset: offset)
        var entries: [DictionaryEntry] = []
        entries.reserveCapacity(entryIDs.count)
        for entryID in entryIDs {
            if let entry = try lookupEntry(entryID: entryID) {
                entries.append(entry)
            }
        }
        return entries
    }

    // Returns entry ids ordered by ascending frequency rank, `limit` rows starting at `offset`.
    // entry_id breaks rank ties so consecutive pages never overlap or skip.
    nonisolated private func fetchTopFrequencyEntryIDs(limit: Int, offset: Int) throws -> [Int64] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT entry_id, MIN(frequency_rank) AS best_rank
            FROM word_frequency
            WHERE frequency_rank IS NOT NULL
            GROUP BY entry_id
            ORDER BY best_rank ASC, entry_id ASC
            LIMIT ?1 OFFSET ?2
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindInt64(Int64(limit), index: 1, statement: statement)
            try bindInt64(Int64(offset), index: 2, statement: statement)

            return try stepRows(statement: statement) { stmt in
                Int64(sqlite3_column_int64(stmt, 0))
            }
        }
    }


    // Builds the unified per-surface reading and frequency map from the materialized surface_readings table.
    // Ordered by (surface ASC, has_direct_rank DESC, best_rank ASC, reading_order ASC, wordfreq_zipf DESC, reading ASC).
    //
    // reading_order (JMdict's listing order) breaks best_rank ties before wordfreq_zipf: Jiten ranks
    // every reading of an entry the same (今日 = 93 for きょう and こんにち), and JMdict lists the
    // common reading first.
    //
    // has_direct_rank comes first: best_rank is an entry-wide value shared by every reading of a
    // multi-reading entry (the frequency list ranks written forms, not every reading) — a reading with no rank of its
    // own just INHERITS the entry's best_rank from whichever sibling reading actually earned it,
    // which makes it tie exactly with that sibling's best_rank. has_direct_rank (1 = this exact
    // pair has its own kanji_kana_links.frequency_rank, 0 = inherited-only) breaks that tie in favor of
    // the reading that's actually ranked, before best_rank is even consulted — without it, 夜
    // defaulted to よ (inherited rank 357, tied with よる's real rank 357) because the NEXT
    // tiebreaker, wordfreq_zipf, is corpus-noise-inflated for short/common-mora readings like よ.
    // (frequency_rank itself can't make this distinction — generate_db.py's materialization already
    // COALESCEs it to the entry-wide fallback, so both よ and よる show frequency_rank=357 there.)
    //
    // wordfreq_zipf still breaks ties WITHIN a has_direct_rank/best_rank tier by actual usage
    // before falling back to alphabetical — without it, ties fell through to plain alphabetical
    // order on the reading string, which is why 二人 defaulted to ににん (に < ふ) and 一人 to
    // いちにん (い < ひ) instead of the common ふたり/ひとり. Both fixes mirror generate_db.py's
    // own materialization ORDER BY.
    //
    // Each surface retains up to maxReadingsPerSurface distinct readings; frequency data is populated
    // for any reading that has at least one frequency signal (frequency_rank or wordfreq_zipf).
    nonisolated func fetchSurfaceReadingData(maxReadingsPerSurface: Int = 8) throws -> [String: SurfaceReadingData] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT surface, reading, frequency_rank, wordfreq_zipf
            FROM surface_readings
            ORDER BY surface, has_direct_rank DESC, best_rank, reading_order, wordfreq_zipf DESC, reading
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)

            var result: [String: SurfaceReadingData] = [:]
            var currentSurface: String?
            var currentReadings: [String] = []
            var currentFrequency: [String: FrequencyData] = [:]
            var seenReadings = Set<String>()

            // Flushes the accumulated readings and frequency data for the current surface into the result map.
            func flushSurface() {
                guard let surface = currentSurface else { return }
                result[surface] = SurfaceReadingData(
                    readings: currentReadings,
                    frequencyByReading: currentFrequency
                )
            }

            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                guard let surfacePointer = sqlite3_column_text(statement, 0),
                      let readingPointer = sqlite3_column_text(statement, 1) else {
                    stepCode = sqlite3_step(statement)
                    continue
                }

                let surface = String(cString: surfacePointer)
                let reading = String(cString: readingPointer)

                // Detect surface boundary and flush the previous group.
                if surface != currentSurface {
                    flushSurface()
                    currentSurface = surface
                    currentReadings = []
                    currentFrequency = [:]
                    seenReadings = []
                }

                // Collect up to maxReadingsPerSurface distinct readings, ordered by frequency.
                if seenReadings.insert(reading).inserted && currentReadings.count < maxReadingsPerSurface {
                    currentReadings.append(reading)
                }

                // Column 2: frequency_rank (nullable int)
                let frequencyRank: Int? = sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(statement, 2))

                // Column 3: wordfreq_zipf (nullable double)
                let wordfreqZipf: Double? = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 3)

                // Only store frequency data when at least one signal is present.
                if frequencyRank != nil || wordfreqZipf != nil {
                    currentFrequency[reading] = FrequencyData(frequencyRank: frequencyRank, wordfreqZipf: wordfreqZipf)
                }

                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            // Flush the final surface group after the last row.
            flushSurface()

            return result
        }
    }

    // Builds a surface → best frequency rank map (lower = more frequent) directly from `word_frequency`,
    // the table that actually carries frequency_rank.
    //
    // Propagation is per ENTRY, not per writing: the frequency list ranks the entry's written forms (usually the kanji,
    // e.g. 喧嘩), but every writing of that entry is the same word, so we apply the entry's best
    // rank to ALL its kana and kanji surfaces. That rescues alternate writings the segmenter sees in
    // text — ケンカ inherits 喧嘩's rank (3934), わがまま inherits 我儘's (26903) — instead of those
    // kana spellings reading as rank-none. A genuinely unranked entry (たの, an `exp`) stays NONE,
    // which is the signal that distinguishes real words from junk. (Conjugations like 会いたい aren't
    // stored surfaces; they inherit frequency via the deinflected lemma in resolvedTrieLemmas.)
    //
    // This is the propagation `surface_readings` lacks — its kana rows carry NULL frequency_rank — so it
    // backs both the segmenter (via fetchFrequencyScoreBySurface) and the lookup/split-editor
    // frequency fallback (via FrequencyRankMap → frequencyData(forSurface:)).
    nonisolated func fetchBestRankBySurface() throws -> [String: Int] {
        try withSerializedDatabaseAccess {
            var bestRankBySurface: [String: Int] = [:]

            // Runs one (surface, MIN(rank)) query and folds rows into bestRankBySurface, keeping the lowest rank per surface.
            func accumulate(sql: String) throws {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                try prepare(sql: sql, statement: &statement)
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let textPointer = sqlite3_column_text(statement, 0) else { continue }
                    let surface = String(cString: textPointer)
                    let rank = Int(sqlite3_column_int(statement, 1))
                    if let existing = bestRankBySurface[surface], existing <= rank { continue }
                    bestRankBySurface[surface] = rank
                }
            }

            // Per-entry best rank, propagated to every writing of that entry (kana + kanji).
            let entryRankCTE = """
                WITH entry_rank AS (
                    SELECT entry_id, MIN(frequency_rank) AS rank
                    FROM word_frequency WHERE frequency_rank IS NOT NULL GROUP BY entry_id
                )
                """
            try accumulate(sql: entryRankCTE + """
                SELECT kf.text, er.rank
                FROM kana_forms kf JOIN entry_rank er ON er.entry_id = kf.entry_id
                """)
            try accumulate(sql: entryRankCTE + """
                SELECT kj.text, er.rank
                FROM kanji kj JOIN entry_rank er ON er.entry_id = kj.entry_id
                """)

            return bestRankBySurface
        }
    }

    // Surface → frequency-score map (~0–7 Zipf-equivalent, higher = more common) used by the
    // segmenter's cost model. Read from `surface_frequency`, which carries the frequency rank of each
    // surface AS IT IS WRITTEN: する scores by its kana-spelling rank (10), not by its rare kanji
    // form 為る (14848); kana はこ (36205) scores far below 箱 (1975). That orthography match is
    // what lets the segmenter tell a real kana word from a particle fused onto the next word's
    // first kana. (The list also ranks some kana strings nobody writes as a word — がそ for 画素 —
    // which the segmenter's two-kana penalty prices back up; see SegmenterScoring.twoKanaPenalty.)
    // Deliberately NOT the per-entry-propagated ranks of fetchBestRankBySurface — propagation
    // gives every spelling of an entry the same rank, which erases exactly this distinction.
    nonisolated func fetchFrequencyScoreBySurface() throws -> [String: Double] {
        try withSerializedDatabaseAccess {
            var scoreBySurface: [String: Double] = [:]
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: "SELECT surface, frequency_rank FROM surface_frequency", statement: &statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let textPointer = sqlite3_column_text(statement, 0) else { continue }
                let rank = Int(sqlite3_column_int(statement, 1))
                if let score = FrequencyData(frequencyRank: rank, wordfreqZipf: nil).normalizedScore, score > 0 {
                    scoreBySurface[String(cString: textPointer)] = score
                }
            }
            return scoreBySurface
        }
    }

    // Kana spellings JMdict marks as common (a reading carrying ichi1, news1, spec1, spec2 or gai1 —
    // jmdict-simplified's own definition of "common"). The segmenter uses it to tell a real short kana
    // word (のみ, よみ, なる) from a kana fragment a frequency list happens to rank (まお, いよ).
    nonisolated func fetchCommonKanaSurfaces() throws -> Set<String> {
        try withSerializedDatabaseAccess {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: """
                SELECT DISTINCT text FROM kana_forms
                WHERE ',' || priority || ',' GLOB '*,ichi1,*' OR ',' || priority || ',' GLOB '*,news1,*'
                   OR ',' || priority || ',' GLOB '*,spec1,*' OR ',' || priority || ',' GLOB '*,spec2,*'
                   OR ',' || priority || ',' GLOB '*,gai1,*'
                """, statement: &statement)
            let surfaces = try stepRows(statement: statement) { stmt in
                sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            }
            return Set(surfaces)
        }
    }

    // Fetches all unique dictionary surfaces from kanji and kana_forms tables.
    nonisolated public func fetchAllSurfaces() throws -> [String] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT DISTINCT text FROM kanji
            UNION
            SELECT DISTINCT text FROM kana_forms
            ORDER BY text ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)

            var surfaces: [String] = []
            var stepCode = sqlite3_step(statement)

            while stepCode == SQLITE_ROW {
                if let textPointer = sqlite3_column_text(statement, 0) {
                    surfaces.append(String(cString: textPointer))
                }
                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            return surfaces
        }
    }
}

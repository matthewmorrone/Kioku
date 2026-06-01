import Foundation
import SQLite3

// Frequency query surface — builds the unified surface reading map used by segmentation, furigana, and frequency display.
extension DictionaryStore {

    // Fetches the top N dictionary entries by JPDB frequency rank, materialized for browse-view display.
    // Entries with multiple readings collapse to their best-ranked reading (MIN(jpdb_rank)).
    nonisolated func fetchTopFrequencyEntries(limit: Int) throws -> [DictionaryEntry] {
        let entryIDs = try fetchTopFrequencyEntryIDs(limit: limit)
        var entries: [DictionaryEntry] = []
        entries.reserveCapacity(entryIDs.count)
        for entryID in entryIDs {
            if let entry = try lookupEntry(entryID: entryID) {
                entries.append(entry)
            }
        }
        return entries
    }

    // Returns entry ids ordered by ascending JPDB rank, capped at `limit`.
    nonisolated private func fetchTopFrequencyEntryIDs(limit: Int) throws -> [Int64] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT entry_id, MIN(jpdb_rank) AS best_rank
            FROM word_frequency
            WHERE jpdb_rank IS NOT NULL
            GROUP BY entry_id
            ORDER BY best_rank ASC
            LIMIT ?1
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindInt64(Int64(limit), index: 1, statement: statement)

            return try stepRows(statement: statement) { stmt in
                Int64(sqlite3_column_int64(stmt, 0))
            }
        }
    }


    // Builds the unified per-surface reading and frequency map from the materialized surface_readings table.
    // Rows are pre-sorted by (surface ASC, best_rank ASC, reading ASC) at DB generation time,
    // so a single sequential scan produces correctly-ordered readings without runtime sorting.
    // Each surface retains up to maxReadingsPerSurface distinct readings; frequency data is populated
    // for any reading that has at least one frequency signal (jpdb_rank or wordfreq_zipf).
    nonisolated func fetchSurfaceReadingData(maxReadingsPerSurface: Int = 8) throws -> [String: SurfaceReadingData] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT surface, reading, jpdb_rank, wordfreq_zipf
            FROM surface_readings
            ORDER BY surface, best_rank, reading
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

                // Column 2: jpdb_rank (nullable int)
                let jpdbRank: Int? = sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(statement, 2))

                // Column 3: wordfreq_zipf (nullable double)
                let wordfreqZipf: Double? = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 3)

                // Only store frequency data when at least one signal is present.
                if jpdbRank != nil || wordfreqZipf != nil {
                    currentFrequency[reading] = FrequencyData(jpdbRank: jpdbRank, wordfreqZipf: wordfreqZipf)
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

    // Builds a surface → frequency-score map (~0–7 Zipf-equivalent, higher = more common) directly
    // from `word_frequency`, the table that actually carries jpdb_rank.
    //
    // Propagation is per ENTRY, not per writing: jpdb ranks one written form (usually the kanji,
    // e.g. 喧嘩), but every writing of that entry is the same word, so we apply the entry's best
    // rank to ALL its kana and kanji surfaces. That rescues alternate writings the segmenter sees in
    // text — ケンカ inherits 喧嘩's rank (3207), わがまま inherits 我儘's (14647) — instead of those
    // kana spellings reading as rank-none. A genuinely unranked entry (たの, an `exp`) stays NONE,
    // which is the signal that distinguishes real words from junk. Rank→score reuses FrequencyData
    // so the mapping matches every other frequency consumer. (Conjugations like 会いたい aren't stored
    // surfaces; they inherit frequency via the deinflected lemma in resolvedTrieLemmas.)
    nonisolated func fetchFrequencyScoreBySurface() throws -> [String: Double] {
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
                    SELECT entry_id, MIN(jpdb_rank) AS rank
                    FROM word_frequency WHERE jpdb_rank IS NOT NULL GROUP BY entry_id
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

            var scoreBySurface: [String: Double] = [:]
            scoreBySurface.reserveCapacity(bestRankBySurface.count)
            for (surface, rank) in bestRankBySurface {
                if let score = FrequencyData(jpdbRank: rank, wordfreqZipf: nil).normalizedScore, score > 0 {
                    scoreBySurface[surface] = score
                }
            }
            return scoreBySurface
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

import Foundation
import SQLite3

// Frequency query surface — builds maps and candidate lists used by segmentation and furigana pipelines.
extension DictionaryStore {

    // Builds a surface→reading→FrequencyData nested map for per-reading frequency lookups.
    // The outer key is the surface text (kanji or kana); the inner key is the reading (kana text).
    // For kanji surfaces the reading comes from kanji_kana_links; for kana-only entries the reading equals the surface.
    // Entries absent from both JPDB and wordfreq datasets are excluded.
    public func fetchFrequencyDataBySurface() throws -> [String: [String: FrequencyData]] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT surface, reading, MIN(jpdb_rank), MAX(wordfreq_zipf) FROM (
                SELECT k.text AS surface, kf.text AS reading, kkl.jpdb_rank, k.wordfreq_zipf
                FROM kanji_kana_links kkl
                JOIN kanji k ON k.id = kkl.kanji_id
                JOIN kana_forms kf ON kf.id = kkl.kana_id
                UNION ALL
                SELECT kf.text, kf.text, NULL, kf.wordfreq_zipf
                FROM kana_forms kf
                WHERE kf.entry_id NOT IN (SELECT entry_id FROM kanji)
            )
            GROUP BY surface, reading
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)

            var dataByS: [String: [String: FrequencyData]] = [:]
            var stepCode = sqlite3_step(statement)

            while stepCode == SQLITE_ROW {
                guard let surfacePointer = sqlite3_column_text(statement, 0) else {
                    stepCode = sqlite3_step(statement)
                    continue
                }
                let surface = String(cString: surfacePointer)

                guard let readingPointer = sqlite3_column_text(statement, 1) else {
                    stepCode = sqlite3_step(statement)
                    continue
                }
                let reading = String(cString: readingPointer)

                // Column 2: jpdb_rank (nullable int)
                let jpdbRank: Int? = sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(statement, 2))

                // Column 3: wordfreq_zipf (nullable double)
                let wordfreqZipf: Double? = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 3)

                // Only include entries where at least one frequency signal is present.
                guard jpdbRank != nil || wordfreqZipf != nil else {
                    stepCode = sqlite3_step(statement)
                    continue
                }

                dataByS[surface, default: [:]][reading] = FrequencyData(jpdbRank: jpdbRank, wordfreqZipf: wordfreqZipf)
                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            return dataByS
        }
    }

    // Fetches all unique dictionary surfaces from kanji and kana_forms tables.
    public func fetchAllSurfaces() throws -> [String] {
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

    // Builds a preferred surface-to-reading map for fast in-memory furigana lookups.
    // Ordered by best JPDB rank so the most common reading is picked first.
    public func fetchPreferredReadingsBySurface() throws -> [String: String] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT kj.text AS surface, kf.text AS reading,
                   MIN(COALESCE(kkl.jpdb_rank, 9999999)) AS best_rank
            FROM kanji kj
            JOIN kana_forms kf ON kf.entry_id = kj.entry_id
            LEFT JOIN kanji_kana_links kkl ON kkl.kanji_id = kj.id AND kkl.kana_id = kf.id
            GROUP BY kj.text, kf.text
            ORDER BY kj.text ASC, best_rank ASC, kf.text ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)

            var readingsBySurface: [String: String] = [:]
            var stepCode = sqlite3_step(statement)

            while stepCode == SQLITE_ROW {
                guard
                    let surfacePointer = sqlite3_column_text(statement, 0),
                    let readingPointer = sqlite3_column_text(statement, 1)
                else {
                    stepCode = sqlite3_step(statement)
                    continue
                }

                let surface = String(cString: surfacePointer)
                let reading = String(cString: readingPointer)

                // Keep first-seen reading because SQL ordering already prioritizes by frequency.
                if readingsBySurface[surface] == nil {
                    readingsBySurface[surface] = reading
                }

                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            return readingsBySurface
        }
    }

    // Builds bounded per-surface reading candidates for lightweight disambiguation heuristics.
    public func fetchReadingCandidatesBySurface(maxReadingsPerSurface: Int = 8) throws -> [String: [String]] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT kj.text AS surface, kf.text AS reading,
                   MIN(COALESCE(kkl.jpdb_rank, 9999999)) AS best_rank
            FROM kanji kj
            JOIN kana_forms kf ON kf.entry_id = kj.entry_id
            LEFT JOIN kanji_kana_links kkl ON kkl.kanji_id = kj.id AND kkl.kana_id = kf.id
            GROUP BY kj.text, kf.text
            ORDER BY kj.text ASC, best_rank ASC, kf.text ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)

            var candidatesBySurface: [String: [String]] = [:]
            var seenBySurface: [String: Set<String>] = [:]

            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                guard
                    let surfacePointer = sqlite3_column_text(statement, 0),
                    let readingPointer = sqlite3_column_text(statement, 1)
                else {
                    stepCode = sqlite3_step(statement)
                    continue
                }

                let surface = String(cString: surfacePointer)
                let reading = String(cString: readingPointer)

                var seenReadings = seenBySurface[surface, default: Set<String>()]
                if !seenReadings.contains(reading) {
                    seenReadings.insert(reading)
                    seenBySurface[surface] = seenReadings

                    var candidates = candidatesBySurface[surface, default: []]
                    if candidates.count < maxReadingsPerSurface {
                        candidates.append(reading)
                        candidatesBySurface[surface] = candidates
                    }
                }

                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            return candidatesBySurface
        }
    }
}

import Foundation
import SQLite3

// Frequency query surface — builds the unified surface reading map used by segmentation, furigana, and frequency display.
extension DictionaryStore {

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

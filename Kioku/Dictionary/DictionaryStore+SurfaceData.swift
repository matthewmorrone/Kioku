import Foundation
import SQLite3

// Bulk surface and POS data loading for trie construction and Viterbi scoring.
extension DictionaryStore {

    // Convenience wrapper returning only the surface records from a full surface data scan.
    public func fetchSurfaceRecords() throws -> [SurfaceRecord] {
        try fetchSurfaceData().surfaceRecords
    }

    // Fetches trie surface records and per-entry POS bits in one bulk sqlite scan.
    // Groups rows by surface text, accumulating entry IDs and OR-ing POS bits within each group.
    public func fetchSurfaceData() throws -> DictionarySurfaceData {
        let sql = """
        WITH surfaces AS (
            SELECT text, entry_id FROM kana_forms
            UNION ALL
            SELECT text, entry_id FROM kanji
        )
        SELECT sf.text, sf.entry_id, s.pos
        FROM surfaces sf
        LEFT JOIN senses s ON s.entry_id = sf.entry_id
        ORDER BY sf.text ASC, sf.entry_id ASC, s.order_index ASC, s.id ASC
        """

        return try withSerializedDatabaseAccess {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)

            var records: [SurfaceRecord] = []
            var currentSurface: String?
            var currentEntryIDs = Set<Int>()
            var currentPOS: UInt64 = 0
            var partOfSpeechByEntryID: [Int: UInt64] = [:]

            // Flushes the current surface group into the output record list.
            func flushCurrentSurface() {
                guard let surface = currentSurface else { return }
                records.append(SurfaceRecord(
                    surface: surface,
                    entryIDs: Array(currentEntryIDs).sorted(),
                    partOfSpeech: currentPOS
                ))
            }

            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                guard let textPointer = sqlite3_column_text(statement, 0) else {
                    stepCode = sqlite3_step(statement)
                    continue
                }
                let surface = String(cString: textPointer)
                let entryID = Int(sqlite3_column_int64(statement, 1))
                let pos = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                let posBits = PartOfSpeech.bits(from: pos)

                if currentSurface != surface {
                    flushCurrentSurface()
                    currentSurface = surface
                    currentEntryIDs = []
                    currentPOS = 0
                }

                currentEntryIDs.insert(entryID)
                currentPOS |= posBits
                partOfSpeechByEntryID[entryID, default: 0] |= posBits

                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            flushCurrentSurface()
            return DictionarySurfaceData(
                surfaceRecords: records,
                partOfSpeechByEntryID: partOfSpeechByEntryID
            )
        }
    }
}

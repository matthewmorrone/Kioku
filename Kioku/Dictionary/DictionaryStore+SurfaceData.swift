import Foundation
import SQLite3

// Bulk surface and POS data loading for trie construction and Viterbi scoring.
extension DictionaryStore {

    // Convenience wrapper returning only the surface records from a full surface data scan.
    nonisolated public func fetchSurfaceRecords() throws -> [SurfaceRecord] {
        try fetchSurfaceData().surfaceRecords
    }

    // Fetches trie surface records and per-entry POS bits without the JOIN-explosion that
    // OOM-killed the app on devices. Two passes:
    //   1. SELECT entry_id, GROUP_CONCAT(pos) FROM senses GROUP BY entry_id
    //      → one row per entry (~500k), POS strings comma-joined. Small.
    //   2. SELECT text, entry_id FROM kana_forms UNION ALL kanji
    //      → one row per surface row (~500k). Joined against the in-memory POS map.
    // Total memory: a [Int: UInt64] POS map (~16 MB) + result records. No multiplicative blow-up
    // from the sense-row JOIN that the previous implementation triggered.
    nonisolated public func fetchSurfaceData() throws -> DictionarySurfaceData {
        return try withSerializedDatabaseAccess {
            // Pass 1: entry_id → OR-merged POS bits, materialized once.
            var posByEntryID: [Int: UInt64] = [:]
            posByEntryID.reserveCapacity(600_000)

            var posStatement: OpaquePointer?
            try prepare(sql: """
                SELECT entry_id, GROUP_CONCAT(pos || CASE WHEN ',' || COALESCE(misc, '') || ',' LIKE '%,on-mim,%' THEN ',on-mim' ELSE '' END, ',')
                FROM senses
                GROUP BY entry_id
            """, statement: &posStatement)

            var posStep = sqlite3_step(posStatement)
            while posStep == SQLITE_ROW {
                let entryID = Int(sqlite3_column_int64(posStatement, 0))
                let posString = sqlite3_column_text(posStatement, 1).map { String(cString: $0) }
                let bits = PartOfSpeech.bits(from: posString)
                if bits != 0 { posByEntryID[entryID] = bits }
                posStep = sqlite3_step(posStatement)
            }
            sqlite3_finalize(posStatement)
            guard posStep == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            // Pass 2: surface rows, grouped by surface text.
            var surfaceStatement: OpaquePointer?
            try prepare(sql: """
                SELECT text, entry_id FROM kana_forms
                UNION ALL
                SELECT text, entry_id FROM kanji
                ORDER BY text ASC, entry_id ASC
            """, statement: &surfaceStatement)
            defer { sqlite3_finalize(surfaceStatement) }

            var records: [SurfaceRecord] = []
            records.reserveCapacity(500_000)
            var currentSurface: String?
            var currentEntryIDs = Set<Int>()
            var currentPOS: UInt64 = 0

            // Flush accumulator into the output record list.
            func flushCurrentSurface() {
                guard let surface = currentSurface else { return }
                records.append(SurfaceRecord(
                    surface: surface,
                    entryIDs: Array(currentEntryIDs).sorted(),
                    partOfSpeech: currentPOS
                ))
            }

            var step = sqlite3_step(surfaceStatement)
            while step == SQLITE_ROW {
                guard let textPointer = sqlite3_column_text(surfaceStatement, 0) else {
                    step = sqlite3_step(surfaceStatement)
                    continue
                }
                let surface = String(cString: textPointer)
                let entryID = Int(sqlite3_column_int64(surfaceStatement, 1))

                if currentSurface != surface {
                    flushCurrentSurface()
                    currentSurface = surface
                    currentEntryIDs = []
                    currentPOS = 0
                }

                currentEntryIDs.insert(entryID)
                currentPOS |= posByEntryID[entryID] ?? 0

                step = sqlite3_step(surfaceStatement)
            }

            guard step == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            flushCurrentSurface()
            return DictionarySurfaceData(
                surfaceRecords: records,
                partOfSpeechByEntryID: posByEntryID
            )
        }
    }
}

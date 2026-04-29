import Foundation
import SQLite3

// Builds the surface → canonical entry id map that lets saved-word identity resolution
// run as in-memory hashtable lookups instead of per-surface SQL fallbacks. Populated
// once at app start by makeReadResources before the store is published to the UI.
extension DictionaryStore {

    // Computes the full surface → canonical entry id map in one query. Selection priority
    // matches lookupFirstEntryID (jpdb rank → sense order → entry id) so any saved-word
    // identity resolved through the map matches what an interactive tap would produce.
    // Runs once at startup; intermediate result-set is one row per (surface, entry) pair
    // before the window function trims to one row per surface.
    nonisolated func fetchCanonicalEntryIDMap() throws -> [String: Int64] {
        try withSerializedDatabaseAccess {
            let sql = """
            WITH surfaces_with_entries AS (
                SELECT text AS surface, entry_id FROM kanji
                UNION ALL
                SELECT text AS surface, entry_id FROM kana_forms
            ),
            m AS (
                SELECT s.surface, s.entry_id,
                       MIN(wf.jpdb_rank) AS rank,
                       COALESCE(MIN(sn.order_index), 2147483647) AS min_sense
                FROM surfaces_with_entries s
                LEFT JOIN word_frequency wf ON wf.entry_id = s.entry_id
                    AND (EXISTS (SELECT 1 FROM kana_forms kf2 WHERE kf2.id = wf.kana_id AND kf2.text = s.surface)
                      OR EXISTS (SELECT 1 FROM kanji kj2 WHERE kj2.id = wf.kanji_id AND kj2.text = s.surface))
                LEFT JOIN senses sn ON sn.entry_id = s.entry_id
                GROUP BY s.surface, s.entry_id
            ),
            ranked AS (
                SELECT surface, entry_id,
                       ROW_NUMBER() OVER (
                           PARTITION BY surface
                           ORDER BY COALESCE(rank, 9999999) ASC, min_sense ASC, entry_id ASC
                       ) AS rn
                FROM m
            )
            SELECT surface, entry_id FROM ranked WHERE rn = 1
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)

            var map: [String: Int64] = [:]
            map.reserveCapacity(500_000)

            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                guard let surfacePointer = sqlite3_column_text(statement, 0) else {
                    stepCode = sqlite3_step(statement)
                    continue
                }
                let surface = String(cString: surfacePointer)
                let entryID = sqlite3_column_int64(statement, 1)
                map[surface] = entryID
                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            return map
        }
    }

    // Populates the in-memory canonical entry id map. Must be called once at app start
    // before the store is published to the UI; safe because makeReadResources runs the
    // population synchronously off the main actor, then hops back to publish — by which
    // point any subsequent reader sees the populated map under Swift's happens-before.
    nonisolated func populateCanonicalEntryIDMap() throws {
        canonicalEntryIDMap = try fetchCanonicalEntryIDMap()
    }
}

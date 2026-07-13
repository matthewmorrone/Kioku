import Foundation
import SQLite3

// Builds the surface → canonical entry id map that lets saved-word identity resolution
// run as in-memory hashtable lookups instead of per-surface SQL fallbacks. Populated
// once at app start by makeReadResources before the store is published to the UI.
extension DictionaryStore {

    // Reads the surface → canonical entry id map from surface_canonical_entry, precomputed at
    // DB-build time by generate_db.py's materialize_canonical_entry_ids (same selection
    // priority as fetchMatchedEntries: functional/deictic POS → kana-only → jpdb/wordfreq rank
    // → sense order → entry id — kept in exact lockstep, see that Python function's comment).
    // This used to run the whole ranking query (a window function over a multi-way join across
    // all ~450k surfaces) at every app startup — ~2.5-4s of a ~7s cold start on-device, measured
    // via StartupTimer — for a result that's a pure function of static dictionary data and never
    // changes at runtime. Now it's a plain indexed table scan.
    nonisolated func fetchCanonicalEntryIDMap() throws -> [String: Int64] {
        try withSerializedDatabaseAccess {
            let sql = "SELECT surface, entry_id FROM surface_canonical_entry"

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

    // Reads the ent_seq ⇄ entries.id mapping in one pass over the entries table.
    nonisolated func fetchEntSeqMaps() throws -> (entryIDByEntSeq: [Int64: Int64], entSeqByEntryID: [Int64: Int64]) {
        try withSerializedDatabaseAccess {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: "SELECT id, ent_seq FROM entries WHERE ent_seq IS NOT NULL", statement: &statement)

            var byEntSeq: [Int64: Int64] = [:]
            var byEntryID: [Int64: Int64] = [:]
            byEntSeq.reserveCapacity(300_000)
            byEntryID.reserveCapacity(300_000)

            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                let entryID = sqlite3_column_int64(statement, 0)
                let entSeq = sqlite3_column_int64(statement, 1)
                byEntSeq[entSeq] = entryID
                byEntryID[entryID] = entSeq
                stepCode = sqlite3_step(statement)
            }
            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }
            return (byEntSeq, byEntryID)
        }
    }

    // Populates the in-memory ent_seq maps. Same startup lifecycle contract as
    // populateCanonicalEntryIDMap (run off-main before the store is published).
    nonisolated func populateEntSeqMaps() throws {
        let maps = try fetchEntSeqMaps()
        entryIDByEntSeq = maps.entryIDByEntSeq
        entSeqByEntryID = maps.entSeqByEntryID
    }
}

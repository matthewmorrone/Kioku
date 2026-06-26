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
            // Mirrors the ordering in DictionaryStore.fetchMatchedEntries so the canonical
            // id resolved at app start matches what an interactive lookup would produce.
            // Kana-only entries (no kanji form) fall back from a missing jpdb_rank to a
            // wordfreq Zipf bucket; otherwise the particle の would resolve to 野 because
            // 野 has a JPDB rank and the particle entry has none.
            let sql = """
            WITH surfaces_with_entries AS (
                SELECT text AS surface, entry_id FROM kanji
                UNION ALL
                SELECT text AS surface, entry_id FROM kana_forms
            ),
            m AS (
                SELECT s.surface, s.entry_id,
                       MIN(wf.jpdb_rank) AS rank,
                       MAX(wf.wordfreq_zipf) AS best_zipf,
                       EXISTS (SELECT 1 FROM kanji k WHERE k.entry_id = s.entry_id) AS has_kanji,
                       -- Particle / copula / auxiliary detection — any sense tagged as
                       -- functional grammar makes the entry a strong match for bare-kana
                       -- lookups. Matches archaic-kanji-bearing particles (の:乃,之 etc.)
                       -- that the has_kanji=0 tier alone would miss.
                       EXISTS (
                           SELECT 1 FROM senses sp WHERE sp.entry_id = s.entry_id
                           AND (sp.pos = 'prt' OR sp.pos LIKE 'prt,%' OR sp.pos LIKE '%,prt,%' OR sp.pos LIKE '%,prt'
                             OR sp.pos = 'cop' OR sp.pos LIKE 'cop,%' OR sp.pos LIKE '%,cop,%' OR sp.pos LIKE '%,cop'
                             OR sp.pos = 'aux' OR sp.pos LIKE 'aux,%' OR sp.pos LIKE '%,aux,%' OR sp.pos LIKE '%,aux'
                             OR sp.pos LIKE 'aux-%' OR sp.pos LIKE '%,aux-%'
                             OR sp.pos = 'adj-pn' OR sp.pos LIKE 'adj-pn,%' OR sp.pos LIKE '%,adj-pn,%' OR sp.pos LIKE '%,adj-pn')
                       ) AS is_particle,
                       COALESCE(MIN(sn.order_index), \(FrequencySQL.noSenseSort)) AS min_sense
                FROM surfaces_with_entries s
                LEFT JOIN word_frequency wf ON wf.entry_id = s.entry_id
                    AND (EXISTS (SELECT 1 FROM kana_forms kf2 WHERE kf2.id = wf.kana_id AND kf2.text = s.surface)
                      OR EXISTS (SELECT 1 FROM kanji kj2 WHERE kj2.id = wf.kanji_id AND kj2.text = s.surface))
                LEFT JOIN senses sn ON sn.entry_id = s.entry_id
                GROUP BY s.surface, s.entry_id
            ),
            ranked AS (
                -- Primary tier: kana-only entries (has_kanji=0) win over kanji entries
                -- whose kana reading happens to match. For kanji surfaces this is a no-op
                -- (kana_forms.text never holds a kanji character, so all candidates have
                -- has_kanji=1). For kana surfaces this fixes the homophone collision —
                -- tapping は returns the topic particle, not 派 "group; faction".
                SELECT surface, entry_id,
                       ROW_NUMBER() OVER (
                           PARTITION BY surface
                           ORDER BY
                               -- Particle/functional first, then kana-only, then by rank.
                               -- See DictionaryStore.fetchMatchedEntries for the rationale.
                               CASE WHEN is_particle = 1 THEN 0 ELSE 1 END ASC,
                               has_kanji ASC,
                               -- Effective rank applied uniformly to kanji and kana-only
                               -- entries: JPDB rank if present, else a pseudo-rank from the
                               -- wordfreq Zipf score, else the catch-all. Mirrors the live
                               -- lookup query in DictionaryStore.fetchMatchedEntries so the
                               -- canonical id at app start matches an interactive lookup.
                               \(FrequencySQL.effectiveRank(jpdbExpr: "rank", zipfExpr: "best_zipf")) ASC,
                               min_sense ASC,
                               entry_id ASC
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

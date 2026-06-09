import Foundation

// Single source of truth for the frequency-based ranking SQL shared by the live lookup
// (DictionaryStore.fetchMatchedEntries) and the startup canonical-id map
// (DictionaryStore.fetchCanonicalEntryIDMap). The two queries MUST rank candidates
// identically — otherwise the canonical entry id resolved for a saved word at app start
// disagrees with what an interactive tap produces. Before extraction the Zipf→pseudo-rank
// bucket table and the COALESCE wrapper were typed out inline in both queries (and in
// generate_db.py), so a recalibration meant editing several copies in lockstep.
extension DictionaryStore {
    nonisolated enum FrequencySQL {
        // Sort key for entries with no frequency signal at all — sorts to the very bottom.
        static let unrankedSort = "9999999"

        // Sort key for entries with no senses (COALESCE fallback for MIN(order_index)). INT_MAX.
        static let noSenseSort = "2147483647"

        // Maps a wordfreq Zipf score (general-corpus log frequency) to a JPDB-comparable
        // pseudo-rank. Zipf 7+ ≈ top-30 word, 6+ ≈ top-1k, etc.; bucket boundaries are
        // deliberately wider than JPDB's so a high-confidence corpus signal beats a
        // low-confidence JPDB ranking. `zipfExpr` is the SQL expression that yields the
        // Zipf score in the calling query (e.g. "MAX(wf.wordfreq_zipf)" or "best_zipf").
        static func zipfPseudoRank(_ zipfExpr: String) -> String {
            """
            CASE
                WHEN \(zipfExpr) >= 7.0 THEN 5
                WHEN \(zipfExpr) >= 6.5 THEN 25
                WHEN \(zipfExpr) >= 6.0 THEN 100
                WHEN \(zipfExpr) >= 5.5 THEN 300
                WHEN \(zipfExpr) >= 5.0 THEN 1000
                WHEN \(zipfExpr) >= 4.5 THEN 3000
                WHEN \(zipfExpr) >= 4.0 THEN 10000
                WHEN \(zipfExpr) >= 3.5 THEN 30000
                WHEN \(zipfExpr) >= 3.0 THEN 100000
                ELSE 500000
            END
            """
        }

        // Effective rank used in ORDER BY: JPDB rank if present, else the wordfreq Zipf
        // pseudo-rank, else the unranked sentinel. `jpdbExpr` is the SQL expression that
        // yields the JPDB rank (e.g. "MIN(wf.jpdb_rank)" or "rank").
        static func effectiveRank(jpdbExpr: String, zipfExpr: String) -> String {
            """
            COALESCE(
                \(jpdbExpr),
                \(zipfPseudoRank(zipfExpr)),
                \(unrankedSort)
            )
            """
        }
    }
}

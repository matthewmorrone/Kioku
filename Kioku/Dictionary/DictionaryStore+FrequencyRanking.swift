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

        // Extra ORDER BY tier, evaluated BEFORE effectiveRank, that stops the zipf pseudo-rank
        // from rescuing an entry past a SIBLING entry (same surface) that has a genuine JPDB
        // rank. wordfreq_zipf on a kanji row is scored on the literal string, identically for
        // every entry that writes it — it was never picking whether a bare-kanji surface like
        // 日 named the common noun (ひ, jpdb_rank 223) or a niche colloquial counter suffix
        // (ち, no jpdb_rank of its own); it was just repeating 日-the-character's overall
        // corpus ubiquity. Without this tier, that borrowed score fell into the zipf pseudo-rank
        // bucket table below and numerically beat the noun's real rank. `jpdbExpr` is this
        // candidate's own rank; `surfaceHasRealRankExpr` is a group-wide signal (e.g. a window
        // function over all candidates for the surface) that's non-null when at least one
        // candidate in the group has a real rank. When NO candidate in the group has any real
        // JPDB coverage, this tier is a no-op (everyone lands in tier 0) and effectiveRank's
        // zipf-beats-a-weak-rank behavior still applies exactly as before.
        static func siblingRealRankTier(jpdbExpr: String, surfaceHasRealRankExpr: String) -> String {
            """
            CASE
                WHEN \(jpdbExpr) IS NOT NULL THEN 0
                WHEN \(surfaceHasRealRankExpr) IS NOT NULL THEN 1
                ELSE 0
            END
            """
        }

        // Boolean EXISTS test: true when the entry has any sense tagged as a functional /
        // deictic part of speech — particle (prt), copula (cop), auxiliary (aux / aux-*), or
        // pre-noun adjectival (adj-pn). These are the words a bare-kana lookup almost always
        // intends (は → topic particle, not 派 "faction"; その → demonstrative, not 園 "garden"),
        // which NO frequency signal can express: the functional word and its rare-kanji
        // homograph share the same kana surface, so they score identically. This is the one
        // definition shared by the live lookup (fetchMatchedEntries) and the startup canonical-id
        // map (fetchCanonicalEntryIDMap) so the two rankings cannot drift out of lockstep — the
        // whole reason this enum exists. It replaced two copy-pasted inline copies; to add a POS
        // to the boost, edit generate_db.py's _FUNCTIONAL_POS_TAGS (this reads a table
        // precomputed at DB-build time, not senses.pos directly — see entry_functional_pos's
        // comment in generate_db.py for why: the original correlated EXISTS + LIKE '%,tag,%'
        // subquery, fine for one entry at a time, cost ~4s of a ~7s cold start when
        // fetchCanonicalEntryIDMap evaluated it across all ~450k dictionary surfaces).
        // `entryIDExpr` names the candidate entry's id in the calling query.
        static func functionalPosMatch(entryIDExpr: String) -> String {
            "EXISTS (SELECT 1 FROM entry_functional_pos efp WHERE efp.entry_id = \(entryIDExpr))"
        }
    }
}

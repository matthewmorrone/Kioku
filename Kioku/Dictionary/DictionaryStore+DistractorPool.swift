import Foundation
import SQLite3

// One dictionary entry's minimal display data for Multiple Choice's distractor pool. Raw JMdict
// pos tags rather than a collapsed WordClass — that collapsing (see `WordClass.from(posTags:)`)
// is a Learn-layer concept the Dictionary layer doesn't otherwise depend on.
struct DictionaryDistractorRow: Sendable {
    let kanji: String?
    let kana: String?
    let gloss: String?
    let posTags: [String]
}

extension DictionaryStore {
    // A broad, frequency-ranked slice of the dictionary — independent of anything the learner has
    // saved — used to widen Multiple Choice's distractor pool when the learner's own saved words
    // can't supply enough same-word-class, same-form near-misses to make a fair question. Without
    // this, a thin saved pool (e.g. only a handful of other verbs) forces weak distractors that
    // are guessable on sight rather than on knowledge of the word.
    //
    // Each entry's kanji form is limited to the first one not tagged rare/outdated/irregular/
    // search-only (mirrors `DictionaryEntry.firstEverydayKanji`), so a distractor is never spelled
    // a way the learner could never plausibly have seen. Ordered by frequency (most common first)
    // and capped at `limit` so this stays a one-time, bounded cost per session rather than a scan
    // of the whole dictionary.
    nonisolated func fetchDistractorPool(limit: Int = 3000) throws -> [DictionaryDistractorRow] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT
                (SELECT k.text FROM kanji k
                 WHERE k.entry_id = e.id
                   AND (k.info IS NULL OR (
                        k.info NOT LIKE '%rK%' AND k.info NOT LIKE '%oK%'
                        AND k.info NOT LIKE '%iK%' AND k.info NOT LIKE '%sK%'))
                 ORDER BY k.id LIMIT 1) AS kanji,
                (SELECT kf.text FROM kana_forms kf
                 WHERE kf.entry_id = e.id
                 ORDER BY kf.id LIMIT 1) AS kana,
                (SELECT g.gloss FROM glosses g
                 JOIN senses s2 ON s2.id = g.sense_id
                 WHERE s2.entry_id = e.id
                 ORDER BY s2.order_index, g.order_index LIMIT 1) AS gloss,
                (SELECT GROUP_CONCAT(DISTINCT s3.pos) FROM senses s3
                 WHERE s3.entry_id = e.id AND s3.pos IS NOT NULL) AS pos_concat,
                MIN(wf.jpdb_rank) AS best_rank
            FROM entries e
            JOIN word_frequency wf ON wf.entry_id = e.id
            GROUP BY e.id
            ORDER BY (best_rank IS NULL) ASC, best_rank ASC, e.id ASC
            LIMIT ?1
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            try bindInt64(Int64(limit), index: 1, statement: statement)

            return try stepRows(statement: statement) { stmt in
                let kanji = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
                let kana = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let gloss = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let posConcat = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let posTags = posConcat?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.isEmpty == false } ?? []
                guard kanji != nil || kana != nil else { return nil }
                return DictionaryDistractorRow(kanji: kanji, kana: kana, gloss: gloss, posTags: posTags)
            }
        }
    }
}

import Foundation
import SQLite3

// JLPT proficiency-level surface. Levels are stored per ENTRY in entry_jlpt_level (built from the
// Tanos / Jonathan Waller CC BY lists; unofficial estimates) as the N-number directly:
// 5 = N5 (easiest) … 1 = N1 (hardest). Two access shapes:
//   - jlptLevel(for:)  — O(1) in-memory lookup off jlptLevelMap, for filtering saved words.
//   - fetchEntriesByJLPT(level:limit:) — materialized entries for the Browse-by-level view.
extension DictionaryStore {

    // Lowest (easiest) and highest (hardest) stored level values; N5…N1 map to 5…1.
    static let jlptLevelRange = 1...5

    // Renders a stored level integer as its JLPT label, e.g. 5 → "N5". nil passes through.
    nonisolated static func jlptLabel(for level: Int?) -> String? {
        guard let level else { return nil }
        return "N\(level)"
    }

    // O(1) level lookup for an entry. nil when the entry carries no JLPT level (not in the list).
    // Reads the map populated at startup; safe under the same happens-before as the other caches.
    nonisolated func jlptLevel(for entryID: Int64) -> Int? {
        jlptLevelMap[entryID]
    }

    // Loads the entire entry_jlpt_level table into a Swift dictionary. Small (~8k rows); one scan.
    // Tolerates the table being absent (older DB without the migration) by returning empty.
    nonisolated func fetchJLPTLevelMap() throws -> [Int64: Int] {
        try withSerializedDatabaseAccess {
            guard tableExists("entry_jlpt_level") else { return [:] }

            let sql = "SELECT entry_id, level FROM entry_jlpt_level"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)

            var map: [Int64: Int] = [:]
            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                let entryID = Int64(sqlite3_column_int64(statement, 0))
                let level = Int(sqlite3_column_int(statement, 1))
                map[entryID] = level
                stepCode = sqlite3_step(statement)
            }
            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }
            return map
        }
    }

    // Populates the in-memory JLPT level map. Must run once at app start before the store is
    // published to the UI, mirroring populateCanonicalEntryIDMap's lifecycle contract.
    nonisolated func populateJLPTLevelMap() throws {
        jlptLevelMap = try fetchJLPTLevelMap()
    }

    // Fetches entries at a JLPT level, ordered by JPDB frequency (most frequent first; unranked
    // last), materialized for the Browse-by-level view. `limit` nil fetches every entry at the
    // level. Returns [] if the table is absent so the view can show its "no data" state.
    nonisolated func fetchEntriesByJLPT(level: Int, limit: Int? = nil) throws -> [DictionaryEntry] {
        let entryIDs = try fetchEntryIDsByJLPT(level: level, limit: limit)
        guard entryIDs.isEmpty == false else { return [] }
        return try lookupEntries(entryIDs: entryIDs)
    }

    // Returns entry ids at `level`, ordered by best (lowest) JPDB rank with unranked entries last.
    nonisolated private func fetchEntryIDsByJLPT(level: Int, limit: Int?) throws -> [Int64] {
        try withSerializedDatabaseAccess {
            guard tableExists("entry_jlpt_level") else { return [] }

            var sql = """
            SELECT ejl.entry_id, MIN(wf.jpdb_rank) AS best_rank
            FROM entry_jlpt_level ejl
            LEFT JOIN word_frequency wf
                ON wf.entry_id = ejl.entry_id AND wf.jpdb_rank IS NOT NULL
            WHERE ejl.level = ?1
            GROUP BY ejl.entry_id
            ORDER BY (best_rank IS NULL), best_rank ASC, ejl.entry_id ASC
            """
            if limit != nil { sql += "\nLIMIT ?2" }

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)
            try bindInt64(Int64(level), index: 1, statement: statement)
            if let limit { try bindInt64(Int64(limit), index: 2, statement: statement) }

            return try stepRows(statement: statement) { stmt in
                Int64(sqlite3_column_int64(stmt, 0))
            }
        }
    }

    // True when a table of the given name exists — lets JLPT reads degrade gracefully on a
    // dictionary built before the entry_jlpt_level migration. Caller must already hold the queue.
    nonisolated private func tableExists(_ name: String) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1 LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard (try? prepare(sql: sql, statement: &statement)) != nil else { return false }
        sqlite3_bind_text(statement, 1, name, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

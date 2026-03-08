import Foundation
import SQLite3

public final class DictionaryStore {
    private var db: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // Resolves and opens the bundled dictionary database by resource name.
    public convenience init(
        databaseName: String = "dictionary",
        databaseExtension: String = "sqlite",
        bundle: Bundle = .main
    ) throws {
        guard let url = bundle.url(forResource: databaseName, withExtension: databaseExtension) else {
            throw DictionarySQLiteError.databaseNotFound(name: "\(databaseName).\(databaseExtension)")
        }
        try self.init(databaseURL: url)
    }

    // Opens a read-only sqlite connection at a concrete file URL.
    public init(databaseURL: URL) throws {
        var connection: OpaquePointer?
        let code = sqlite3_open_v2(databaseURL.path, &connection, SQLITE_OPEN_READONLY, nil)
        guard code == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown sqlite open error"
            sqlite3_close(connection)
            throw DictionarySQLiteError.openDatabase(message: message)
        }

        db = connection
    }

    // Closes the sqlite connection when the store is released.
    deinit {
        sqlite3_close(db)
    }

    // Performs lookup with an explicit mode so callers own script-policy decisions.
    public func lookup(surface: String, mode: LookupMode) throws -> [DictionaryEntry] {
        try lookupEntries(surface: surface, matchKana: true, matchKanji: mode.allowsKanjiMatching)
    }

    // Performs a kana-only lookup using explicit lookup mode policy.
    public func lookupExactKana(surface: String) throws -> [DictionaryEntry] {
        try lookup(surface: surface, mode: .kanaOnly)
    }

    // Performs an exact kanji match for the provided surface string.
    public func lookupExactKanji(surface: String) throws -> [DictionaryEntry] {
        try lookupEntries(surface: surface, matchKana: false, matchKanji: true)
    }

    // Fetches all unique dictionary surfaces from kana and kanji tables.
    public func fetchAllSurfaces() throws -> [String] {
        let sql = """
        SELECT text FROM kana_forms
        UNION
        SELECT text FROM kanji
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

    // Builds a preferred surface-to-reading map for fast in-memory furigana lookups.
    public func fetchPreferredReadingsBySurface() throws -> [String: String] {
        let sql = """
        SELECT kj.text AS surface, kf.text AS reading, e.is_common
        FROM kanji kj
        JOIN entries e ON e.id = kj.entry_id
        JOIN kana_forms kf ON kf.entry_id = e.id
        ORDER BY kj.text ASC, e.is_common DESC, kf.text ASC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)

        var readingsBySurface: [String: String] = [:]
        var stepCode = sqlite3_step(statement)

        while stepCode == SQLITE_ROW {
            guard
                let surfacePointer = sqlite3_column_text(statement, 0),
                let readingPointer = sqlite3_column_text(statement, 1)
            else {
                stepCode = sqlite3_step(statement)
                continue
            }

            let surface = String(cString: surfacePointer)
            let reading = String(cString: readingPointer)

            // Keep first-seen reading because SQL ordering already prioritizes common entries.
            if readingsBySurface[surface] == nil {
                readingsBySurface[surface] = reading
            }

            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        return readingsBySurface
    }

    // Builds bounded per-surface reading candidates for lightweight disambiguation heuristics.
    public func fetchReadingCandidatesBySurface(maxReadingsPerSurface: Int = 8) throws -> [String: [String]] {
        let sql = """
        SELECT kj.text AS surface, kf.text AS reading, e.is_common
        FROM kanji kj
        JOIN entries e ON e.id = kj.entry_id
        JOIN kana_forms kf ON kf.entry_id = e.id
        ORDER BY kj.text ASC, e.is_common DESC, kf.text ASC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)

        var candidatesBySurface: [String: [String]] = [:]
        var seenBySurface: [String: Set<String>] = [:]

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            guard
                let surfacePointer = sqlite3_column_text(statement, 0),
                let readingPointer = sqlite3_column_text(statement, 1)
            else {
                stepCode = sqlite3_step(statement)
                continue
            }

            let surface = String(cString: surfacePointer)
            let reading = String(cString: readingPointer)

            var seenReadings = seenBySurface[surface, default: Set<String>()]
            if !seenReadings.contains(reading) {
                seenReadings.insert(reading)
                seenBySurface[surface] = seenReadings

                var candidates = candidatesBySurface[surface, default: []]
                if candidates.count < maxReadingsPerSurface {
                    candidates.append(reading)
                    candidatesBySurface[surface] = candidates
                }
            }

            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        return candidatesBySurface
    }

    // Builds fully materialized dictionary entries from matched entry headers.
    private func lookupEntries(surface: String, matchKana: Bool, matchKanji: Bool) throws -> [DictionaryEntry] {
        if surface.isEmpty {
            return []
        }

        let matchedEntries = try fetchMatchedEntries(surface: surface, matchKana: matchKana, matchKanji: matchKanji)
        var results: [DictionaryEntry] = []
        results.reserveCapacity(matchedEntries.count)

        for header in matchedEntries {
            let kanjiForms = try fetchKanjiForms(entryID: header.entryID)
            let kanaForms = try fetchKanaForms(entryID: header.entryID)
            let senses = try fetchSenses(entryID: header.entryID)

            results.append(
                DictionaryEntry(
                    entryId: header.entryID,
                    isCommon: header.isCommon,
                    matchedSurface: surface,
                    kanjiForms: kanjiForms,
                    kanaForms: kanaForms,
                    senses: senses
                )
            )
        }

        return results
    }

    // Fetches distinct entry headers with deterministic ordering by commonness then sense order.
    private func fetchMatchedEntries(surface: String, matchKana: Bool, matchKanji: Bool) throws -> [(entryID: Int64, isCommon: Bool)] {
        let sql = """
        SELECT e.id, e.is_common
        FROM entries e
        LEFT JOIN senses s ON s.entry_id = e.id
        WHERE (
            (?1 = 1 AND EXISTS (
                SELECT 1
                FROM kana_forms kf
                WHERE kf.entry_id = e.id
                  AND kf.text = ?3
            ))
            OR
            (?2 = 1 AND EXISTS (
                SELECT 1
                FROM kanji kj
                WHERE kj.entry_id = e.id
                  AND kj.text = ?3
            ))
        )
        GROUP BY e.id, e.is_common
        ORDER BY e.is_common DESC, COALESCE(MIN(s.order_index), 2147483647) ASC, e.id ASC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        try bindInt(matchKana ? 1 : 0, index: 1, statement: statement)
        try bindInt(matchKanji ? 1 : 0, index: 2, statement: statement)
        try bindText(surface, index: 3, statement: statement)

        var items: [(entryID: Int64, isCommon: Bool)] = []

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {

            // Read entry metadata in the same column order as the SELECT clause.
            let entryID = sqlite3_column_int64(statement, 0)
            let isCommon = sqlite3_column_int(statement, 1) != 0
            items.append((entryID: entryID, isCommon: isCommon))

            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        return items
    }

    // Fetches ordered kanji forms for one entry.
    private func fetchKanjiForms(entryID: Int64) throws -> [String] {
        let sql = """
        SELECT text
        FROM kanji
        WHERE entry_id = ?1
        ORDER BY text ASC
        """

        return try fetchOrderedStrings(sql: sql, entryID: entryID)
    }

    // Fetches ordered kana forms for one entry.
    private func fetchKanaForms(entryID: Int64) throws -> [String] {
        let sql = """
        SELECT text
        FROM kana_forms
        WHERE entry_id = ?1
        ORDER BY text ASC
        """

        return try fetchOrderedStrings(sql: sql, entryID: entryID)
    }

    // Executes a single-column ordered text query and removes duplicates while preserving order.
    private func fetchOrderedStrings(sql: String, entryID: Int64) throws -> [String] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        try bindInt64(entryID, index: 1, statement: statement)

        var items: [String] = []
        var seen = Set<String>()

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            if let textPointer = sqlite3_column_text(statement, 0) {
                let value = String(cString: textPointer)
                // Keep first-seen order to mirror SQL ordering while avoiding duplicates.
                if seen.insert(value).inserted {
                    items.append(value)
                }
            }

            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        return items
    }

    // Fetches senses and ordered glosses for one entry from the normalized tables.
    private func fetchSenses(entryID: Int64) throws -> [DictionaryEntrySense] {
        let sql = """
                SELECT s.id, s.pos, g.gloss
        FROM senses s
        LEFT JOIN glosses g
                    ON g.sense_id = s.id
        WHERE s.entry_id = ?1
        ORDER BY s.order_index ASC, g.order_index ASC, g.id ASC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        try bindInt64(entryID, index: 1, statement: statement)

        var senses: [DictionaryEntrySense] = []
        var currentSenseID: Int64?
        var currentPOS: String?
        var currentGlosses: [String] = []

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {

            let senseID = sqlite3_column_int64(statement, 0)
            let pos = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let gloss = sqlite3_column_text(statement, 2).map { String(cString: $0) }

            if currentSenseID != senseID {
                // Flush the previous sense before starting the next grouped row set.
                if currentSenseID != nil {
                    senses.append(DictionaryEntrySense(pos: currentPOS, glosses: currentGlosses))
                }
                currentSenseID = senseID
                currentPOS = pos
                currentGlosses = []
            }

            if let gloss, !gloss.isEmpty {
                currentGlosses.append(gloss)
            }

            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        // Flush the final grouped sense after stepping completes.
        if currentSenseID != nil {
            senses.append(DictionaryEntrySense(pos: currentPOS, glosses: currentGlosses))
        }

        return senses
    }

    // Compiles SQL into a prepared statement bound to the active connection.
    private func prepare(sql: String, statement: inout OpaquePointer?) throws {
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK else {
            throw DictionarySQLiteError.prepareStatement(sql: sql, message: errorMessage())
        }
    }

    // Binds a text parameter to a prepared statement index.
    private func bindText(_ text: String, index: Int32, statement: OpaquePointer?) throws {
        let code = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
        guard code == SQLITE_OK else {
            throw DictionarySQLiteError.bindParameter(message: errorMessage())
        }
    }

    // Binds a 32-bit integer parameter to a prepared statement index.
    private func bindInt(_ value: Int32, index: Int32, statement: OpaquePointer?) throws {
        let code = sqlite3_bind_int(statement, index, value)
        guard code == SQLITE_OK else {
            throw DictionarySQLiteError.bindParameter(message: errorMessage())
        }
    }

    // Binds a 64-bit integer parameter to a prepared statement index.
    private func bindInt64(_ value: Int64, index: Int32, statement: OpaquePointer?) throws {
        let code = sqlite3_bind_int64(statement, index, value)
        guard code == SQLITE_OK else {
            throw DictionarySQLiteError.bindParameter(message: errorMessage())
        }
    }

    // Reads the most recent sqlite error message from the active connection.
    private func errorMessage() -> String {
        guard let db else { return "Database is not available" }
        return String(cString: sqlite3_errmsg(db))
    }
}

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

    // Routes lookup behavior by script so pure-kana input only hits kana forms.
    public func lookup(surface: String) throws -> [DictionaryEntry] {
        if ScriptClassifier.isPureKana(surface) {
            return try lookupEntries(surface: surface, matchKana: true, matchKanji: false)
        }
        return try lookupEntries(surface: surface, matchKana: true, matchKanji: true)
    }

    // Performs an exact kana_forms match for the provided surface string.
    public func lookupExactKana(surface: String) throws -> [DictionaryEntry] {
        try lookupEntries(surface: surface, matchKana: true, matchKanji: false)
    }

    // Performs an exact kanji match for the provided surface string.
    public func lookupExactKanji(surface: String) throws -> [DictionaryEntry] {
        try lookupEntries(surface: surface, matchKana: false, matchKanji: true)
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
        ORDER BY is_common DESC, priority ASC, id ASC
        """

        return try fetchOrderedStrings(sql: sql, entryID: entryID)
    }

    // Fetches ordered kana forms for one entry.
    private func fetchKanaForms(entryID: Int64) throws -> [String] {
        let sql = """
        SELECT text
        FROM kana_forms
        WHERE entry_id = ?1
        ORDER BY is_common DESC, priority ASC, id ASC
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
        SELECT s.id, s.pos, g.text
        FROM senses s
        LEFT JOIN glosses g
          ON g.sense_id = s.id
         AND g.entry_id = s.entry_id
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

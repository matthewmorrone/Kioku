import Foundation
import SQLite3

// Writes the user's learned spellings into the downloaded dictionary.sqlite, as the rows the
// dictionary builder would have produced for them: a kanji or kana form on the linked entry, or a
// new entry with a reading, sense and gloss. Every read path (trie, deinflection, furigana,
// lookup, search, saved-word identity) then sees them without knowing they're learned.
//
// The file is replaced by each new dictionary release, so this runs before every resource
// rebuild. It is idempotent: each row it inserts is recorded in `learned_word_rows`, and every
// apply first deletes the previously recorded rows. `learned_word_state` holds the applied set, so
// an unchanged set costs one read instead of a rewrite.
nonisolated enum LearnedWordApplier {
    // Negative ent_seq base for learned new words: below every extras.json ent_seq (32-bit) so the
    // two can't collide, and stable per spelling so a saved learned word survives a re-apply.
    private static let newWordEntSeqBase: Int64 = -10_000_000_000

    // Brings the dictionary at `url` in line with `words`. Throws on SQLite failure; the caller
    // logs it and builds resources from whatever the file holds, since lookups must not depend on it.
    static func apply(_ words: [LearnedWord], toDatabaseAt url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(connection)
            throw DictionarySQLiteError.openDatabase(message: message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)

        try execute(db, """
            CREATE TABLE IF NOT EXISTS learned_word_rows (table_name TEXT NOT NULL, row_id INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS learned_word_state (signature TEXT NOT NULL);
            """)

        let signature = String(decoding: try JSONEncoder().encode(words), as: UTF8.self)
        if try appliedSignature(db) == signature { return }

        try execute(db, "BEGIN IMMEDIATE")
        do {
            try removePreviouslyApplied(db)
            for word in words {
                try insert(word, into: db)
            }
            try execute(db, "DELETE FROM learned_word_state")
            try run(db, "INSERT INTO learned_word_state (signature) VALUES (?)", [.text(signature)])
            try execute(db, "COMMIT")
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
    }

    // The stable ent_seq a learned new word is written under, derived from its spelling (FNV-1a),
    // so saving it as a word keeps pointing at it after the next apply.
    static func entSeq(forNewWordSpelling spelling: String) -> Int64 {
        var hash: UInt32 = 2_166_136_261
        for byte in spelling.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return newWordEntSeqBase - Int64(hash)
    }

    // MARK: - Removal

    // Deletes every row a previous apply inserted, search-index entries first (the FTS tables are
    // external-content, so they must be told the old text before the row goes).
    private static func removePreviouslyApplied(_ db: OpaquePointer) throws {
        for (table, fts, column) in [("kanji", "kanji_fts", "text"), ("kana_forms", "kana_forms_fts", "text"), ("glosses", "glosses_fts", "gloss")] {
            try execute(db, """
                INSERT INTO \(fts)(\(fts), rowid, \(column))
                SELECT 'delete', rowid, \(column) FROM \(table)
                WHERE rowid IN (SELECT row_id FROM learned_word_rows WHERE table_name = '\(table)')
                """)
        }
        for table in ["kanji_kana_links", "surface_readings", "surface_canonical_entry", "glosses", "senses", "kanji", "kana_forms", "entries"] {
            try execute(db, "DELETE FROM \(table) WHERE rowid IN (SELECT row_id FROM learned_word_rows WHERE table_name = '\(table)')")
        }
        try execute(db, "DELETE FROM learned_word_rows")
    }

    // MARK: - Insertion

    // Writes one learned word. A spelling of an entry the current dictionary lacks is skipped
    // (logged), so a release that drops an entry can't fail the whole apply.
    private static func insert(_ word: LearnedWord, into db: OpaquePointer) throws {
        let spelling = word.spelling
        switch word.kind {
        case .spellingOf(let entSeq):
            guard let entryID = try queryInt(db, "SELECT id FROM entries WHERE ent_seq = ?", [.int(entSeq)]),
                  let kana = try firstKanaForm(db, entryID: entryID)
            else {
                AppLog.error(.dictionary, "LearnedWordApplier: no entry with ent_seq \(entSeq) for \(spelling)")
                return
            }
            if ScriptClassifier.containsKanji(spelling) {
                let kanjiID = try insertKanji(db, text: spelling, entryID: entryID)
                try insertRecorded(db, table: "kanji_kana_links", "INSERT INTO kanji_kana_links (kanji_id, kana_id) VALUES (?, ?)", [.int(kanjiID), .int(kana.id)])
                try insertSurface(db, surface: spelling, reading: kana.text, readingOrder: kana.id, entryID: entryID)
            } else {
                let kanaID = try insertKana(db, text: spelling, entryID: entryID)
                try insertSurface(db, surface: spelling, reading: spelling, readingOrder: kanaID, entryID: entryID)
            }

        case .newWord(let reading, let meaning):
            let entryID = try insertRecorded(db, table: "entries", "INSERT INTO entries (ent_seq) VALUES (?)", [.int(entSeq(forNewWordSpelling: spelling))])
            let kanaID = try insertKana(db, text: reading, entryID: entryID)
            if ScriptClassifier.containsKanji(spelling) {
                let kanjiID = try insertKanji(db, text: spelling, entryID: entryID)
                try insertRecorded(db, table: "kanji_kana_links", "INSERT INTO kanji_kana_links (kanji_id, kana_id) VALUES (?, ?)", [.int(kanjiID), .int(kanaID)])
                try insertSurface(db, surface: spelling, reading: reading, readingOrder: kanaID, entryID: entryID)
            } else if spelling != reading {
                // A kana spelling other than its reading (katakana written, hiragana read) is a form too.
                let spellingID = try insertKana(db, text: spelling, entryID: entryID)
                try insertSurface(db, surface: spelling, reading: spelling, readingOrder: spellingID, entryID: entryID)
            }
            try insertSurface(db, surface: reading, reading: reading, readingOrder: kanaID, entryID: entryID)
            let senseID = try insertRecorded(db, table: "senses", "INSERT INTO senses (entry_id, order_index) VALUES (?, 0)", [.int(entryID)])
            let glossID = try insertRecorded(db, table: "glosses", "INSERT INTO glosses (sense_id, order_index, gloss) VALUES (?, 0, ?)", [.int(senseID), .text(meaning)])
            try run(db, "INSERT INTO glosses_fts (rowid, gloss) VALUES (?, ?)", [.int(glossID), .text(meaning)])
        }
    }

    // A kanji form plus its search-index row.
    private static func insertKanji(_ db: OpaquePointer, text: String, entryID: Int64) throws -> Int64 {
        let id = try insertRecorded(db, table: "kanji", "INSERT INTO kanji (text, entry_id) VALUES (?, ?)", [.text(text), .int(entryID)])
        try run(db, "INSERT INTO kanji_fts (rowid, text) VALUES (?, ?)", [.int(id), .text(text)])
        return id
    }

    // A kana form plus its search-index row.
    private static func insertKana(_ db: OpaquePointer, text: String, entryID: Int64) throws -> Int64 {
        let id = try insertRecorded(db, table: "kana_forms", "INSERT INTO kana_forms (text, entry_id) VALUES (?, ?)", [.text(text), .int(entryID)])
        try run(db, "INSERT INTO kana_forms_fts (rowid, text) VALUES (?, ?)", [.int(id), .text(text)])
        return id
    }

    // The per-surface rows the furigana resolver and saved-word identity read. Ranked last
    // (9999999, the builder's "unranked"), and the canonical entry only when the surface has none,
    // so a learned spelling never displaces a dictionary word that shares it.
    private static func insertSurface(_ db: OpaquePointer, surface: String, reading: String, readingOrder: Int64, entryID: Int64) throws {
        try insertRecorded(db, table: "surface_readings", """
            INSERT INTO surface_readings (surface, reading, best_rank, has_direct_rank, reading_order)
            VALUES (?, ?, 9999999, 0, ?)
            """, [.text(surface), .text(reading), .int(readingOrder)])
        try run(db, "INSERT OR IGNORE INTO surface_canonical_entry (surface, entry_id) VALUES (?, ?)", [.text(surface), .int(entryID)])
        if sqlite3_changes(db) > 0 {
            try record(db, table: "surface_canonical_entry", rowID: sqlite3_last_insert_rowid(db))
        }
    }

    // The entry's first kana form (JMdict lists the common reading first).
    private static func firstKanaForm(_ db: OpaquePointer, entryID: Int64) throws -> (id: Int64, text: String)? {
        var statement: OpaquePointer?
        let sql = "SELECT id, text FROM kana_forms WHERE entry_id = ? ORDER BY id LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DictionarySQLiteError.prepareStatement(sql: sql, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, entryID)
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 1) else { return nil }
        return (sqlite3_column_int64(statement, 0), String(cString: text))
    }

    // MARK: - SQLite helpers

    // Runs an insert and records the new row so the next apply can remove it.
    @discardableResult
    private static func insertRecorded(_ db: OpaquePointer, table: String, _ sql: String, _ values: [LearnedWordSQLValue]) throws -> Int64 {
        try run(db, sql, values)
        let rowID = sqlite3_last_insert_rowid(db)
        try record(db, table: table, rowID: rowID)
        return rowID
    }

    // Notes one inserted row in learned_word_rows.
    private static func record(_ db: OpaquePointer, table: String, rowID: Int64) throws {
        try run(db, "INSERT INTO learned_word_rows (table_name, row_id) VALUES (?, ?)", [.text(table), .int(rowID)])
    }

    // The signature of the last applied set, nil before the first apply.
    private static func appliedSignature(_ db: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        let sql = "SELECT signature FROM learned_word_state LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DictionarySQLiteError.prepareStatement(sql: sql, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    // A single integer result, nil when the query returns no row.
    private static func queryInt(_ db: OpaquePointer, _ sql: String, _ values: [LearnedWordSQLValue]) throws -> Int64? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DictionarySQLiteError.prepareStatement(sql: sql, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, db: db)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    // Runs one parameterised statement that returns no rows.
    private static func run(_ db: OpaquePointer, _ sql: String, _ values: [LearnedWordSQLValue]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DictionarySQLiteError.prepareStatement(sql: sql, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, db: db)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    // Binds parameters in order; text is copied (SQLITE_TRANSIENT) since the Swift string's storage
    // doesn't outlive the call.
    private static func bind(_ values: [LearnedWordSQLValue], to statement: OpaquePointer?, db: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .int(let number): code = sqlite3_bind_int64(statement, index, number)
            case .text(let string): code = sqlite3_bind_text(statement, index, string, -1, transient)
            }
            guard code == SQLITE_OK else {
                throw DictionarySQLiteError.bindParameter(message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    // Runs one or more unparameterised statements.
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DictionarySQLiteError.step(message: String(cString: sqlite3_errmsg(db)))
        }
    }
}

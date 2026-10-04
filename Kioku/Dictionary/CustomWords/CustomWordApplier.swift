import Foundation
import SQLite3

// Writes the user's Custom Words into the downloaded dictionary.sqlite, in place of the extras.json
// entries the build baked in, as the rows the builder would have produced: a new entry with forms,
// senses and glosses, or extra forms on an existing entry. Every read path (trie, deinflection,
// furigana, lookup, search, saved-word identity) then sees the list without knowing it's custom.
//
// Runs before every resource rebuild. A fresh download still carries the build's extras entries:
// those are read back as CustomWords (returned, so the store can offer the ones it hasn't seen),
// then deleted, so the list alone decides what's there — a deleted default stays deleted. Each row
// this writes is recorded in `custom_word_rows` and removed before the next write;
// `custom_word_state` holds the applied list so an unchanged list costs one read.
nonisolated enum CustomWordApplier {
    // Brings the dictionary at `url` in line with `words`. Returns the build's extras entries whose
    // headword isn't in `offeredDefaultKeys`, written in along with `words`. Throws on SQLite
    // failure; the caller logs it and builds resources from whatever the file holds.
    static func apply(_ words: [CustomWord], offeredDefaultKeys: Set<String>, toDatabaseAt url: URL) throws -> [CustomWord] {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(connection)
            throw DictionarySQLiteError.openDatabase(message: message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)

        try execute(db, """
            CREATE TABLE IF NOT EXISTS custom_word_rows (table_name TEXT NOT NULL, row_id INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS custom_word_state (signature TEXT NOT NULL);
            """)

        let builtInEntryIDs = try queryInts(db, """
            SELECT id FROM entries WHERE ent_seq < 0 AND ent_seq > ?
            AND id NOT IN (SELECT row_id FROM custom_word_rows WHERE table_name = 'entries')
            """, [.int(CustomWordIdentity.newWordEntSeqBase)])
        let builtIns = try builtInEntryIDs.map { try readEntry(db, entryID: $0) }
        let newDefaults = builtIns.filter { offeredDefaultKeys.contains($0.defaultKey ?? "") == false }

        let wordsToWrite = words + newDefaults
        let signature = String(decoding: try JSONEncoder().encode(wordsToWrite), as: UTF8.self)
        if builtInEntryIDs.isEmpty, try appliedSignature(db) == signature { return [] }

        try execute(db, "BEGIN IMMEDIATE")
        do {
            try deleteEntries(db, entryIDs: builtInEntryIDs)
            try removePreviouslyWritten(db)
            for word in wordsToWrite {
                try insert(word, into: db)
            }
            try execute(db, "DELETE FROM custom_word_state")
            try run(db, "INSERT INTO custom_word_state (signature) VALUES (?)", [.text(signature)])
            try execute(db, "COMMIT")
        } catch {
            try? execute(db, "ROLLBACK")
            throw error
        }
        return newDefaults
    }

    // MARK: - Reading the build's extras entries

    // One baked-in extras entry as a CustomWord default, keeping its ent_seq so saved words that
    // point at it still resolve.
    private static func readEntry(_ db: OpaquePointer, entryID: Int64) throws -> CustomWord {
        let entSeq = try queryInts(db, "SELECT ent_seq FROM entries WHERE id = ?", [.int(entryID)]).first
        let kanji = try queryTexts(db, "SELECT text FROM kanji WHERE entry_id = ? ORDER BY id", [.int(entryID)])
        let kana = try queryTexts(db, "SELECT text FROM kana_forms WHERE entry_id = ? ORDER BY id", [.int(entryID)])
        var senses: [CustomWordSense] = []
        for senseRow in try queryRows(db, "SELECT id, coalesce(pos, ''), coalesce(misc, '') FROM senses WHERE entry_id = ? ORDER BY order_index", [.int(entryID)]) {
            let glosses = try queryTexts(db, "SELECT gloss FROM glosses WHERE sense_id = ? ORDER BY order_index", [.int(Int64(senseRow[0]) ?? 0)])
            senses.append(CustomWordSense(
                partOfSpeech: codes(senseRow[1]),
                misc: codes(senseRow[2]),
                glosses: glosses
            ))
        }
        var word = CustomWord(id: UUID(), entSeq: entSeq, sameAsEntSeq: nil, kanji: kanji, kana: kana, senses: senses, defaultKey: nil)
        word.defaultKey = CustomWordIdentity.headword(of: word)
        return word
    }

    // Splits a comma-joined code column (the builder's format) into its codes.
    private static func codes(_ joined: String) -> [String] {
        joined.split(separator: ",").map(String.init).filter { $0.isEmpty == false }
    }

    // MARK: - Removal

    // Deletes whole entries (the build's extras) from every table that refers to them. Surface rows
    // go only for surfaces no remaining form has, so a JMdict word sharing a spelling keeps its own.
    private static func deleteEntries(_ db: OpaquePointer, entryIDs: [Int64]) throws {
        guard entryIDs.isEmpty == false else { return }
        let ids = entryIDs.map(String.init).joined(separator: ",")
        let senses = "SELECT id FROM senses WHERE entry_id IN (\(ids))"
        let kanji = "SELECT id FROM kanji WHERE entry_id IN (\(ids))"
        let kana = "SELECT id FROM kana_forms WHERE entry_id IN (\(ids))"
        let surfaces = try queryTexts(db, "SELECT text FROM kanji WHERE entry_id IN (\(ids)) UNION SELECT text FROM kana_forms WHERE entry_id IN (\(ids))", [])
        try execute(db, """
            INSERT INTO kanji_fts(kanji_fts, rowid, text) SELECT 'delete', id, text FROM kanji WHERE entry_id IN (\(ids));
            INSERT INTO kana_forms_fts(kana_forms_fts, rowid, text) SELECT 'delete', id, text FROM kana_forms WHERE entry_id IN (\(ids));
            INSERT INTO glosses_fts(glosses_fts, rowid, gloss) SELECT 'delete', id, gloss FROM glosses WHERE sense_id IN (\(senses));
            DELETE FROM kanji_kana_links WHERE kanji_id IN (\(kanji)) OR kana_id IN (\(kana));
            DELETE FROM word_frequency WHERE entry_id IN (\(ids));
            DELETE FROM glosses WHERE sense_id IN (\(senses));
            DELETE FROM sense_restrictions WHERE sense_id IN (\(senses));
            DELETE FROM sense_references WHERE sense_id IN (\(senses));
            DELETE FROM lsource WHERE sense_id IN (\(senses));
            DELETE FROM senses WHERE entry_id IN (\(ids));
            DELETE FROM entry_decomposition WHERE entry_id IN (\(ids));
            DELETE FROM entry_jlpt_level WHERE entry_id IN (\(ids));
            DELETE FROM entry_functional_pos WHERE entry_id IN (\(ids));
            DELETE FROM surface_canonical_entry WHERE entry_id IN (\(ids));
            DELETE FROM kanji WHERE entry_id IN (\(ids));
            DELETE FROM kana_forms WHERE entry_id IN (\(ids));
            DELETE FROM entries WHERE id IN (\(ids));
            """)
        for surface in surfaces {
            let stillUsed = try queryInts(db, "SELECT 1 FROM kanji WHERE text = ?1 UNION SELECT 1 FROM kana_forms WHERE text = ?1", [.text(surface)])
            if stillUsed.isEmpty {
                try run(db, "DELETE FROM surface_readings WHERE surface = ?", [.text(surface)])
                try run(db, "DELETE FROM surface_frequency WHERE surface = ?", [.text(surface)])
            }
        }
    }

    // Deletes every row a previous apply wrote, search-index entries first (the FTS tables are
    // external-content, so they must be told the old text before the row goes).
    private static func removePreviouslyWritten(_ db: OpaquePointer) throws {
        for (table, fts, column) in [("kanji", "kanji_fts", "text"), ("kana_forms", "kana_forms_fts", "text"), ("glosses", "glosses_fts", "gloss")] {
            try execute(db, """
                INSERT INTO \(fts)(\(fts), rowid, \(column))
                SELECT 'delete', rowid, \(column) FROM \(table)
                WHERE rowid IN (SELECT row_id FROM custom_word_rows WHERE table_name = '\(table)')
                """)
        }
        for table in ["kanji_kana_links", "surface_readings", "surface_canonical_entry", "glosses", "senses", "kanji", "kana_forms", "entries"] {
            try execute(db, "DELETE FROM \(table) WHERE rowid IN (SELECT row_id FROM custom_word_rows WHERE table_name = '\(table)')")
        }
        try execute(db, "DELETE FROM custom_word_rows")
    }

    // MARK: - Insertion

    // Writes one custom word. A spelling of an entry this dictionary lacks, or a new word whose
    // ent_seq is taken, is skipped (logged) so one bad word can't fail the whole list.
    private static func insert(_ word: CustomWord, into db: OpaquePointer) throws {
        if let sameAs = word.sameAsEntSeq {
            guard let entryID = try queryInts(db, "SELECT id FROM entries WHERE ent_seq = ?", [.int(sameAs)]).first,
                  let firstKana = try queryRows(db, "SELECT id, text FROM kana_forms WHERE entry_id = ? ORDER BY id LIMIT 1", [.int(entryID)]).first,
                  let firstKanaID = Int64(firstKana[0])
            else {
                AppLog.error(.dictionary, "CustomWordApplier: no entry with ent_seq \(sameAs) for \(CustomWordIdentity.headword(of: word))")
                return
            }
            // With kanji spellings, the word's kana is their reading (馳け寄って read かけよって), not a
            // spelling of its own; without one the entry's first reading stands in.
            let reading = word.kanji.isEmpty ? firstKana[1] : (word.kana.first ?? firstKana[1])
            for text in word.kanji {
                let kanjiID = try insertForm(db, table: "kanji", fts: "kanji_fts", text: text, entryID: entryID)
                try insertRecorded(db, table: "kanji_kana_links", "INSERT INTO kanji_kana_links (kanji_id, kana_id) VALUES (?, ?)", [.int(kanjiID), .int(firstKanaID)])
                try insertSurface(db, surface: text, reading: reading, readingOrder: firstKanaID, entryID: entryID)
            }
            for text in word.kanji.isEmpty ? word.kana : [] {
                let kanaID = try insertForm(db, table: "kana_forms", fts: "kana_forms_fts", text: text, entryID: entryID)
                try insertSurface(db, surface: text, reading: text, readingOrder: kanaID, entryID: entryID)
            }
            return
        }

        let entSeq = word.entSeq ?? CustomWordIdentity.entSeq(forHeadword: CustomWordIdentity.headword(of: word))
        guard try queryInts(db, "SELECT id FROM entries WHERE ent_seq = ?", [.int(entSeq)]).isEmpty else {
            AppLog.error(.dictionary, "CustomWordApplier: ent_seq \(entSeq) already used; skipping \(CustomWordIdentity.headword(of: word))")
            return
        }
        let entryID = try insertRecorded(db, table: "entries", "INSERT INTO entries (ent_seq) VALUES (?)", [.int(entSeq)])
        var kanaIDs: [(id: Int64, text: String)] = []
        for text in word.kana {
            let kanaID = try insertForm(db, table: "kana_forms", fts: "kana_forms_fts", text: text, entryID: entryID)
            kanaIDs.append((kanaID, text))
            try insertSurface(db, surface: text, reading: text, readingOrder: kanaID, entryID: entryID)
        }
        for text in word.kanji {
            let kanjiID = try insertForm(db, table: "kanji", fts: "kanji_fts", text: text, entryID: entryID)
            for kana in kanaIDs {
                try insertRecorded(db, table: "kanji_kana_links", "INSERT INTO kanji_kana_links (kanji_id, kana_id) VALUES (?, ?)", [.int(kanjiID), .int(kana.id)])
                try insertSurface(db, surface: text, reading: kana.text, readingOrder: kana.id, entryID: entryID)
            }
        }
        for (index, sense) in word.senses.enumerated() {
            let senseID = try insertRecorded(db, table: "senses", "INSERT INTO senses (entry_id, order_index, pos, misc) VALUES (?, ?, nullif(?, ''), nullif(?, ''))", [
                .int(entryID), .int(Int64(index)), .text(sense.partOfSpeech.joined(separator: ",")), .text(sense.misc.joined(separator: ",")),
            ])
            for (glossIndex, gloss) in sense.glosses.enumerated() {
                let glossID = try insertRecorded(db, table: "glosses", "INSERT INTO glosses (sense_id, order_index, gloss) VALUES (?, ?, ?)", [.int(senseID), .int(Int64(glossIndex)), .text(gloss)])
                try run(db, "INSERT INTO glosses_fts (rowid, gloss) VALUES (?, ?)", [.int(glossID), .text(gloss)])
            }
        }
    }

    // A kanji or kana form plus its search-index row.
    private static func insertForm(_ db: OpaquePointer, table: String, fts: String, text: String, entryID: Int64) throws -> Int64 {
        let id = try insertRecorded(db, table: table, "INSERT INTO \(table) (text, entry_id) VALUES (?, ?)", [.text(text), .int(entryID)])
        try run(db, "INSERT INTO \(fts) (rowid, text) VALUES (?, ?)", [.int(id), .text(text)])
        return id
    }

    // The per-surface rows the furigana resolver and saved-word identity read. Ranked last
    // (9999999, the builder's "unranked"), and the canonical entry only when the surface has none,
    // so a custom word never displaces a dictionary word that shares its spelling.
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

    // MARK: - SQLite helpers

    // Runs an insert and records the new row so the next apply can remove it.
    @discardableResult
    private static func insertRecorded(_ db: OpaquePointer, table: String, _ sql: String, _ values: [CustomWordSQLValue]) throws -> Int64 {
        try run(db, sql, values)
        let rowID = sqlite3_last_insert_rowid(db)
        try record(db, table: table, rowID: rowID)
        return rowID
    }

    // Notes one written row in custom_word_rows.
    private static func record(_ db: OpaquePointer, table: String, rowID: Int64) throws {
        try run(db, "INSERT INTO custom_word_rows (table_name, row_id) VALUES (?, ?)", [.text(table), .int(rowID)])
    }

    // The signature of the last applied list, nil before the first apply.
    private static func appliedSignature(_ db: OpaquePointer) throws -> String? {
        try queryTexts(db, "SELECT signature FROM custom_word_state LIMIT 1", []).first
    }

    // Every row of a query, each column read as text.
    private static func queryRows(_ db: OpaquePointer, _ sql: String, _ values: [CustomWordSQLValue]) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DictionarySQLiteError.prepareStatement(sql: sql, message: describe(db, sql))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, db: db)
        var rows: [[String]] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: describe(db, sql))
        }
        return rows
    }

    // The first column of every row, as text.
    private static func queryTexts(_ db: OpaquePointer, _ sql: String, _ values: [CustomWordSQLValue]) throws -> [String] {
        try queryRows(db, sql, values).compactMap(\.first)
    }

    // The first column of every row, as integers.
    private static func queryInts(_ db: OpaquePointer, _ sql: String, _ values: [CustomWordSQLValue]) throws -> [Int64] {
        try queryTexts(db, sql, values).compactMap { Int64($0) }
    }

    // Runs one parameterised statement that returns no rows.
    private static func run(_ db: OpaquePointer, _ sql: String, _ values: [CustomWordSQLValue]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DictionarySQLiteError.prepareStatement(sql: sql, message: describe(db, sql))
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, db: db)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: describe(db, sql))
        }
    }

    // Binds parameters in order; text is copied (SQLITE_TRANSIENT) since the Swift string's storage
    // doesn't outlive the call.
    private static func bind(_ values: [CustomWordSQLValue], to statement: OpaquePointer?, db: OpaquePointer) throws {
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
            throw DictionarySQLiteError.step(message: describe(db, sql))
        }
    }

    // SQLite's message with its extended code and the statement, so a failure on the phone says
    // which write failed and why (SQLITE_IOERR alone has a dozen causes).
    private static func describe(_ db: OpaquePointer, _ sql: String) -> String {
        "\(String(cString: sqlite3_errmsg(db))) (\(sqlite3_extended_errcode(db))) in: \(sql.prefix(120))"
    }
}

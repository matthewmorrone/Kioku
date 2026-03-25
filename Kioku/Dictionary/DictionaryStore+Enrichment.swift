import Foundation
import SQLite3

// Enrichment query surface — pitch accent, example sentences, sense metadata, and KANJIDIC2 lookups.
extension DictionaryStore {

    // Fetches pitch accent records for a word+kana pair from the UniDic-derived pitch_accent table.
    public func fetchPitchAccent(word: String, kana: String) throws -> [PitchAccent] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT word, kana, kind, accent, morae
            FROM pitch_accent
            WHERE word = ?1 AND kana = ?2
            ORDER BY id ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindText(word, index: 1, statement: statement)
            try bindText(kana, index: 2, statement: statement)

            return try stepRows(statement: statement) { stmt in
                guard
                    let wordPointer = sqlite3_column_text(stmt, 0),
                    let kanaPointer = sqlite3_column_text(stmt, 1)
                else { return nil }

                // accent and morae are NOT NULL in the schema; treat a NULL as data corruption.
                guard
                    sqlite3_column_type(stmt, 3) != SQLITE_NULL,
                    sqlite3_column_type(stmt, 4) != SQLITE_NULL
                else {
                    throw DictionarySQLiteError.corruptRow(
                        message: "NULL accent or morae in pitch_accent for word=\(word), kana=\(kana)"
                    )
                }

                return PitchAccent(
                    word: String(cString: wordPointer),
                    kana: String(cString: kanaPointer),
                    kind: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                    accent: Int(sqlite3_column_int(stmt, 3)),
                    morae: Int(sqlite3_column_int(stmt, 4))
                )
            }
        }
    }

    // Fetches all example sentence pairs whose Japanese text contains the given surface string.
    // Uses FTS5 for fast substring search, deduplicates on Japanese text, sorted shortest first.
    public func fetchSentencePairs(surface: String) throws -> [SentencePair] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT sp.japanese, sp.english
            FROM sentence_pairs sp
            JOIN sentence_pairs_fts ON sentence_pairs_fts.rowid = sp.rowid
            WHERE sentence_pairs_fts MATCH ?1
            ORDER BY LENGTH(sp.japanese) ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            // FTS5 phrase search wraps the term in quotes for exact substring matching.
            try bindText("\"\(surface)\"", index: 1, statement: statement)

            let all = try stepRows(statement: statement) { stmt -> SentencePair? in
                guard
                    let japanesePointer = sqlite3_column_text(stmt, 0),
                    let englishPointer = sqlite3_column_text(stmt, 1)
                else { return nil }

                return SentencePair(
                    japanese: String(cString: japanesePointer),
                    english: String(cString: englishPointer)
                )
            }

            // Deduplicate on Japanese text, preserving shortest-first order.
            var seen = Set<String>()
            return all.filter { seen.insert($0.japanese).inserted }
        }
    }

    // Fetches sense-level stagk/stagr application restrictions for one entry.
    // Each restriction identifies which kanji or kana form a particular sense applies to.
    public func fetchSenseRestrictions(entryID: Int64) throws -> [SenseRestriction] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT s.order_index, sr.type, sr.value
            FROM sense_restrictions sr
            JOIN senses s ON s.id = sr.sense_id
            WHERE s.entry_id = ?1
            ORDER BY s.order_index ASC, sr.type ASC, sr.value ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindInt64(entryID, index: 1, statement: statement)

            return try stepRows(statement: statement) { stmt in
                let senseOrderIndex = Int(sqlite3_column_int(stmt, 0))
                guard
                    let typeStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                    let type = SenseRestrictionKind(rawValue: typeStr),
                    let valuePointer = sqlite3_column_text(stmt, 2)
                else { return nil }

                return SenseRestriction(
                    senseOrderIndex: senseOrderIndex,
                    type: type,
                    value: String(cString: valuePointer)
                )
            }
        }
    }

    // Fetches sense-level xref/ant cross-reference and antonym records for one entry.
    public func fetchSenseReferences(entryID: Int64) throws -> [SenseReference] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT s.order_index, sr.type, sr.target
            FROM sense_references sr
            JOIN senses s ON s.id = sr.sense_id
            WHERE s.entry_id = ?1
            ORDER BY s.order_index ASC, sr.type ASC, sr.target ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindInt64(entryID, index: 1, statement: statement)

            return try stepRows(statement: statement) { stmt in
                let senseOrderIndex = Int(sqlite3_column_int(stmt, 0))
                guard
                    let typeStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                    let type = SenseReferenceKind(rawValue: typeStr),
                    let targetPointer = sqlite3_column_text(stmt, 2)
                else { return nil }

                return SenseReference(
                    senseOrderIndex: senseOrderIndex,
                    type: type,
                    target: String(cString: targetPointer)
                )
            }
        }
    }

    // Fetches lsource loanword-origin records for one entry.
    public func fetchLoanwordSources(entryID: Int64) throws -> [LoanwordSource] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT s.order_index, ls.lang, ls.ls_wasei, ls.ls_type, ls.content
            FROM lsource ls
            JOIN senses s ON s.id = ls.sense_id
            WHERE s.entry_id = ?1
            ORDER BY s.order_index ASC, ls.id ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindInt64(entryID, index: 1, statement: statement)

            return try stepRows(statement: statement) { stmt in
                let senseOrderIndex = Int(sqlite3_column_int(stmt, 0))
                guard let langPointer = sqlite3_column_text(stmt, 1) else { return nil }

                let wasei = sqlite3_column_int(stmt, 2) != 0
                // Fall back to .part when the column is NULL or contains an unrecognised value.
                let lsTypeStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "part"
                let lsType = LoanwordSourceType(rawValue: lsTypeStr) ?? .part
                let content = sqlite3_column_text(stmt, 4).map { String(cString: $0) }

                return LoanwordSource(
                    senseOrderIndex: senseOrderIndex,
                    lang: String(cString: langPointer),
                    wasei: wasei,
                    lsType: lsType,
                    content: content
                )
            }
        }
    }

    // Fetches KANJIDIC2 metadata for one kanji literal — grade, strokes, JLPT level, on/kun readings, and English meanings.
    // Returns nil when the character is absent from the kanji_characters table.
    func fetchKanjiInfo(for literal: String) throws -> KanjiInfo? {
        try withSerializedDatabaseAccess {
            let charSQL = """
            SELECT grade, stroke_count, jlpt_level
            FROM kanji_characters
            WHERE literal = ?1
            LIMIT 1
            """

            var charStatement: OpaquePointer?
            defer { sqlite3_finalize(charStatement) }
            try prepare(sql: charSQL, statement: &charStatement)
            try bindText(literal, index: 1, statement: charStatement)

            let charStep = sqlite3_step(charStatement)
            guard charStep == SQLITE_ROW else {
                return nil
            }

            let grade = sqlite3_column_type(charStatement, 0) != SQLITE_NULL
                ? Int(sqlite3_column_int(charStatement, 0)) : nil
            let strokeCount = sqlite3_column_type(charStatement, 1) != SQLITE_NULL
                ? Int(sqlite3_column_int(charStatement, 1)) : nil
            let jlptLevel = sqlite3_column_type(charStatement, 2) != SQLITE_NULL
                ? Int(sqlite3_column_int(charStatement, 2)) : nil

            let readingsSQL = """
            SELECT kr.reading, kr.type
            FROM kanji_readings kr
            JOIN kanji_characters kc ON kc.id = kr.kanji_id
            WHERE kc.literal = ?1 AND kr.type IN ('on', 'kun')
            ORDER BY kr.type DESC, kr.id ASC
            """

            var readingsStatement: OpaquePointer?
            defer { sqlite3_finalize(readingsStatement) }
            try prepare(sql: readingsSQL, statement: &readingsStatement)
            try bindText(literal, index: 1, statement: readingsStatement)

            let readingPairs = try stepRows(statement: readingsStatement) { stmt -> (String, String)? in
                guard
                    let readingPointer = sqlite3_column_text(stmt, 0),
                    let typePointer = sqlite3_column_text(stmt, 1)
                else { return nil }
                return (String(cString: readingPointer), String(cString: typePointer))
            }

            var onReadings: [String] = []
            var kunReadings: [String] = []
            for (reading, type) in readingPairs {
                if type == "on" { onReadings.append(reading) } else { kunReadings.append(reading) }
            }

            let meaningsSQL = """
            SELECT km.meaning
            FROM kanji_meanings km
            JOIN kanji_characters kc ON kc.id = km.kanji_id
            WHERE kc.literal = ?1 AND km.lang = 'en'
            ORDER BY km.id ASC
            """

            var meaningsStatement: OpaquePointer?
            defer { sqlite3_finalize(meaningsStatement) }
            try prepare(sql: meaningsSQL, statement: &meaningsStatement)
            try bindText(literal, index: 1, statement: meaningsStatement)

            let meanings = try stepRows(statement: meaningsStatement) { stmt -> String? in
                sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            }

            return KanjiInfo(
                literal: literal,
                grade: grade,
                strokeCount: strokeCount,
                jlptLevel: jlptLevel,
                onReadings: onReadings,
                kunReadings: kunReadings,
                meanings: meanings
            )
        }
    }
}

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

            var results: [PitchAccent] = []
            var stepCode = sqlite3_step(statement)

            while stepCode == SQLITE_ROW {
                guard
                    let wordPointer = sqlite3_column_text(statement, 0),
                    let kanaPointer = sqlite3_column_text(statement, 1)
                else {
                    stepCode = sqlite3_step(statement)
                    continue
                }

                let kind = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                let accent = Int(sqlite3_column_int(statement, 3))
                let morae = Int(sqlite3_column_int(statement, 4))

                results.append(PitchAccent(
                    word: String(cString: wordPointer),
                    kana: String(cString: kanaPointer),
                    kind: kind,
                    accent: accent,
                    morae: morae
                ))

                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            return results
        }
    }

    // Fetches example sentence pairs whose Japanese text contains the given surface string.
    // Capped at 20 results to avoid large result sets for common words.
    public func fetchSentencePairs(surface: String) throws -> [SentencePair] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT japanese, english
            FROM sentence_pairs
            WHERE japanese LIKE ?1
            ORDER BY ja_id ASC
            LIMIT 20
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)
            try bindText("%\(surface)%", index: 1, statement: statement)

            var results: [SentencePair] = []
            var stepCode = sqlite3_step(statement)

            while stepCode == SQLITE_ROW {
                guard
                    let japanesePointer = sqlite3_column_text(statement, 0),
                    let englishPointer = sqlite3_column_text(statement, 1)
                else {
                    stepCode = sqlite3_step(statement)
                    continue
                }

                results.append(SentencePair(
                    japanese: String(cString: japanesePointer),
                    english: String(cString: englishPointer)
                ))

                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            return results
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

            var results: [SenseRestriction] = []
            var stepCode = sqlite3_step(statement)

            while stepCode == SQLITE_ROW {
                let senseOrderIndex = Int(sqlite3_column_int(statement, 0))
                guard
                    let typePointer = sqlite3_column_text(statement, 1),
                    let valuePointer = sqlite3_column_text(statement, 2)
                else {
                    stepCode = sqlite3_step(statement)
                    continue
                }

                results.append(SenseRestriction(
                    senseOrderIndex: senseOrderIndex,
                    type: String(cString: typePointer),
                    value: String(cString: valuePointer)
                ))

                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            return results
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

            var results: [SenseReference] = []
            var stepCode = sqlite3_step(statement)

            while stepCode == SQLITE_ROW {
                let senseOrderIndex = Int(sqlite3_column_int(statement, 0))
                guard
                    let typePointer = sqlite3_column_text(statement, 1),
                    let targetPointer = sqlite3_column_text(statement, 2)
                else {
                    stepCode = sqlite3_step(statement)
                    continue
                }

                results.append(SenseReference(
                    senseOrderIndex: senseOrderIndex,
                    type: String(cString: typePointer),
                    target: String(cString: targetPointer)
                ))

                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            return results
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

            var results: [LoanwordSource] = []
            var stepCode = sqlite3_step(statement)

            while stepCode == SQLITE_ROW {
                let senseOrderIndex = Int(sqlite3_column_int(statement, 0))
                guard let langPointer = sqlite3_column_text(statement, 1) else {
                    stepCode = sqlite3_step(statement)
                    continue
                }

                let wasei = sqlite3_column_int(statement, 2) != 0
                let lsType = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "part"
                let content = sqlite3_column_text(statement, 4).map { String(cString: $0) }

                results.append(LoanwordSource(
                    senseOrderIndex: senseOrderIndex,
                    lang: String(cString: langPointer),
                    wasei: wasei,
                    lsType: lsType,
                    content: content
                ))

                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            return results
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

            var onReadings: [String] = []
            var kunReadings: [String] = []
            var readingsStep = sqlite3_step(readingsStatement)

            while readingsStep == SQLITE_ROW {
                guard
                    let readingPointer = sqlite3_column_text(readingsStatement, 0),
                    let typePointer = sqlite3_column_text(readingsStatement, 1)
                else {
                    readingsStep = sqlite3_step(readingsStatement)
                    continue
                }

                let reading = String(cString: readingPointer)
                let type = String(cString: typePointer)

                if type == "on" {
                    onReadings.append(reading)
                } else {
                    kunReadings.append(reading)
                }

                readingsStep = sqlite3_step(readingsStatement)
            }

            guard readingsStep == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
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

            var meanings: [String] = []
            var meaningsStep = sqlite3_step(meaningsStatement)

            while meaningsStep == SQLITE_ROW {
                if let meaningPointer = sqlite3_column_text(meaningsStatement, 0) {
                    meanings.append(String(cString: meaningPointer))
                }
                meaningsStep = sqlite3_step(meaningsStatement)
            }

            guard meaningsStep == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
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

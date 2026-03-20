import Foundation
import SQLite3

public final class DictionaryStore {
    private var db: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let accessQueue = DispatchQueue(label: "Kioku.DictionaryStore.sqlite.access")

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
        accessQueue.sync {
            _ = sqlite3_close(db)
        }
    }

    // Serializes sqlite access so one DictionaryStore connection is never used from multiple threads at once.
    private func withSerializedDatabaseAccess<T>(_ operation: () throws -> T) rethrows -> T {
        try accessQueue.sync {
            try operation()
        }
    }

    // Performs lookup with an explicit mode so callers own script-policy decisions.
    public func lookup(surface: String, mode: LookupMode) throws -> [DictionaryEntry] {
        try withSerializedDatabaseAccess {
            try lookupEntries(surfaces: lookupSurfaces(for: surface), matchKana: true, matchKanji: mode.allowsKanjiMatching)
        }
    }

    // Performs a kana-only lookup using explicit lookup mode policy.
    public func lookupExactKana(surface: String) throws -> [DictionaryEntry] {
        try withSerializedDatabaseAccess {
            try lookupEntries(surfaces: lookupSurfaces(for: surface), matchKana: true, matchKanji: false)
        }
    }

    // Performs an exact kanji match for the provided surface string.
    public func lookupExactKanji(surface: String) throws -> [DictionaryEntry] {
        try withSerializedDatabaseAccess {
            try lookupEntries(surfaces: lookupSurfaces(for: surface), matchKana: false, matchKanji: true)
        }
    }

    // Fetches one fully materialized entry by ID so UI layers can resolve stable lexeme identifiers.
    public func lookupEntry(entryID: Int64) throws -> DictionaryEntry? {
        try withSerializedDatabaseAccess {
            guard let header = try fetchEntryHeader(entryID: entryID) else {
                return nil
            }

            let kanjiForms = try fetchKanjiForms(entryID: header.entryID)
            let kanaForms = try fetchKanaForms(entryID: header.entryID)
            let senses = try fetchSenses(entryID: header.entryID)
            let matchedSurface = kanjiForms.first ?? kanaForms.first ?? ""

            return DictionaryEntry(
                entryId: header.entryID,
                jpdbRank: header.jpdbRank,
                wordfreqZipf: header.wordfreqZipf,
                matchedSurface: matchedSurface,
                kanjiForms: kanjiForms,
                kanaForms: kanaForms,
                senses: senses
            )
        }
    }

    // Builds a surface→reading→FrequencyData nested map for per-reading frequency lookups.
    // The outer key is the surface text (kanji or kana); the inner key is the reading (kana text).
    // For kanji surfaces the reading comes from kanji_kana_links; for kana-only entries the reading equals the surface.
    // Entries absent from both JPDB and wordfreq datasets are excluded.
    public func fetchFrequencyDataBySurface() throws -> [String: [String: FrequencyData]] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT surface, reading, MIN(jpdb_rank), MAX(wordfreq_zipf) FROM (
                SELECT k.text AS surface, kf.text AS reading, kkl.jpdb_rank, k.wordfreq_zipf
                FROM kanji_kana_links kkl
                JOIN kanji k ON k.id = kkl.kanji_id
                JOIN kana_forms kf ON kf.id = kkl.kana_id
                UNION ALL
                SELECT kf.text, kf.text, NULL, kf.wordfreq_zipf
                FROM kana_forms kf
                WHERE kf.entry_id NOT IN (SELECT entry_id FROM kanji)
            )
            GROUP BY surface, reading
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            try prepare(sql: sql, statement: &statement)

            var dataByS: [String: [String: FrequencyData]] = [:]
            var stepCode = sqlite3_step(statement)

            while stepCode == SQLITE_ROW {
                guard let surfacePointer = sqlite3_column_text(statement, 0) else {
                    stepCode = sqlite3_step(statement)
                    continue
                }
                let surface = String(cString: surfacePointer)

                guard let readingPointer = sqlite3_column_text(statement, 1) else {
                    stepCode = sqlite3_step(statement)
                    continue
                }
                let reading = String(cString: readingPointer)

                // Column 2: jpdb_rank (nullable int)
                let jpdbRank: Int? = sqlite3_column_type(statement, 2) == SQLITE_NULL
                    ? nil
                    : Int(sqlite3_column_int(statement, 2))

                // Column 3: wordfreq_zipf (nullable double)
                let wordfreqZipf: Double? = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_double(statement, 3)

                // Only include entries where at least one frequency signal is present.
                guard jpdbRank != nil || wordfreqZipf != nil else {
                    stepCode = sqlite3_step(statement)
                    continue
                }

                dataByS[surface, default: [:]][reading] = FrequencyData(jpdbRank: jpdbRank, wordfreqZipf: wordfreqZipf)
                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            return dataByS
        }
    }

    // Fetches all unique dictionary surfaces from kanji and kana_forms tables.
    public func fetchAllSurfaces() throws -> [String] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT DISTINCT text FROM kanji
            UNION
            SELECT DISTINCT text FROM kana_forms
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
    }

    // Builds a preferred surface-to-reading map for fast in-memory furigana lookups.
    // Orderd by best JPDB rank so the most common reading is picked first.
    public func fetchPreferredReadingsBySurface() throws -> [String: String] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT kj.text AS surface, kf.text AS reading,
                   MIN(COALESCE(kkl.jpdb_rank, 9999999)) AS best_rank
            FROM kanji kj
            JOIN kana_forms kf ON kf.entry_id = kj.entry_id
            LEFT JOIN kanji_kana_links kkl ON kkl.kanji_id = kj.id AND kkl.kana_id = kf.id
            GROUP BY kj.text, kf.text
            ORDER BY kj.text ASC, best_rank ASC, kf.text ASC
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

                // Keep first-seen reading because SQL ordering already prioritizes by frequency.
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
    }

    // Builds bounded per-surface reading candidates for lightweight disambiguation heuristics.
    public func fetchReadingCandidatesBySurface(maxReadingsPerSurface: Int = 8) throws -> [String: [String]] {
        try withSerializedDatabaseAccess {
            let sql = """
            SELECT kj.text AS surface, kf.text AS reading,
                   MIN(COALESCE(kkl.jpdb_rank, 9999999)) AS best_rank
            FROM kanji kj
            JOIN kana_forms kf ON kf.entry_id = kj.entry_id
            LEFT JOIN kanji_kana_links kkl ON kkl.kanji_id = kj.id AND kkl.kana_id = kf.id
            GROUP BY kj.text, kf.text
            ORDER BY kj.text ASC, best_rank ASC, kf.text ASC
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
    }

    // Builds fully materialized dictionary entries from matched entry headers.
    private func lookupEntries(surfaces: [String], matchKana: Bool, matchKanji: Bool) throws -> [DictionaryEntry] {
        guard surfaces.isEmpty == false else {
            return []
        }

        var matchedEntriesByID: [Int64: (jpdbRank: Int?, wordfreqZipf: Double?, matchedSurface: String)] = [:]

        for surface in surfaces {
            let matchedEntries = try fetchMatchedEntries(surface: surface, matchKana: matchKana, matchKanji: matchKanji)
            for header in matchedEntries {
                if matchedEntriesByID[header.entryID] == nil {
                    matchedEntriesByID[header.entryID] = (
                        jpdbRank: header.jpdbRank,
                        wordfreqZipf: header.wordfreqZipf,
                        matchedSurface: surface
                    )
                }
            }
        }

        // Sort by JPDB rank ascending (lower = more frequent), then entry insertion order.
        let matchedEntries = matchedEntriesByID
            .map { key, value in
                (entryID: key, jpdbRank: value.jpdbRank, wordfreqZipf: value.wordfreqZipf, matchedSurface: value.matchedSurface)
            }
            .sorted { lhs, rhs in
                let lRank = lhs.jpdbRank ?? Int.max
                let rRank = rhs.jpdbRank ?? Int.max
                if lRank != rRank { return lRank < rRank }
                return lhs.entryID < rhs.entryID
            }

        var results: [DictionaryEntry] = []
        results.reserveCapacity(matchedEntries.count)

        for header in matchedEntries {
            let kanjiForms = try fetchKanjiForms(entryID: header.entryID)
            let kanaForms = try fetchKanaForms(entryID: header.entryID)
            let senses = try fetchSenses(entryID: header.entryID)

            results.append(
                DictionaryEntry(
                    entryId: header.entryID,
                    jpdbRank: header.jpdbRank,
                    wordfreqZipf: header.wordfreqZipf,
                    matchedSurface: header.matchedSurface,
                    kanjiForms: kanjiForms,
                    kanaForms: kanaForms,
                    senses: senses
                )
            )
        }

        return results
    }

    // Builds ordered lookup surfaces so iteration-mark expansions and kyujitai forms
    // can resolve through standard dictionary queries.
    private func lookupSurfaces(for surface: String) -> [String] {
        let trimmedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSurface.isEmpty == false else {
            return []
        }

        var orderedSurfaces: [String] = [trimmedSurface]
        let expandedSurfaces = ScriptClassifier.iterationExpandedCandidates(for: trimmedSurface).sorted()
        for expandedSurface in expandedSurfaces where expandedSurface != trimmedSurface {
            orderedSurfaces.append(expandedSurface)
        }

        // Append shinjitai-normalized form as a final fallback so classical text
        // written in kyujitai resolves to JMdict entries that only list the modern form.
        if let normalized = KyujitaiNormalizer.normalize(trimmedSurface),
           orderedSurfaces.contains(normalized) == false {
            orderedSurfaces.append(normalized)
        }

        return orderedSurfaces
    }

    // Fetches entry headers with frequency data, ordered by JPDB rank then sense order.
    private func fetchMatchedEntries(surface: String, matchKana: Bool, matchKanji: Bool) throws -> [(entryID: Int64, jpdbRank: Int?, wordfreqZipf: Double?)] {
        guard matchKana || matchKanji else {
            return []
        }

        let whereClause: String
        if matchKana && matchKanji {
            whereClause = """
            EXISTS (
                SELECT 1 FROM kanji kj WHERE kj.entry_id = e.id AND kj.text = ?1
                UNION ALL
                SELECT 1 FROM kana_forms kf WHERE kf.entry_id = e.id AND kf.text = ?1
            )
            """
        } else if matchKana {
            whereClause = "EXISTS (SELECT 1 FROM kana_forms kf WHERE kf.entry_id = e.id AND kf.text = ?1)"
        } else {
            whereClause = "EXISTS (SELECT 1 FROM kanji kj WHERE kj.entry_id = e.id AND kj.text = ?1)"
        }

        let sql = """
        SELECT e.id,
               MIN(wf.jpdb_rank) AS best_jpdb,
               MAX(wf.wordfreq_zipf) AS best_zipf,
               COALESCE(MIN(s.order_index), 2147483647) AS min_sense
        FROM entries e
        LEFT JOIN word_frequency wf ON wf.entry_id = e.id
        LEFT JOIN senses s ON s.entry_id = e.id
        WHERE \(whereClause)
        GROUP BY e.id
        ORDER BY MIN(COALESCE(wf.jpdb_rank, 9999999)) ASC, min_sense ASC, e.id ASC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        try bindText(surface, index: 1, statement: statement)

        var items: [(entryID: Int64, jpdbRank: Int?, wordfreqZipf: Double?)] = []

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            let entryID = sqlite3_column_int64(statement, 0)
            let jpdbRank = sqlite3_column_type(statement, 1) != SQLITE_NULL
                ? Int(sqlite3_column_int(statement, 1))
                : nil
            let wordfreqZipf = sqlite3_column_type(statement, 2) != SQLITE_NULL
                ? sqlite3_column_double(statement, 2)
                : nil
            items.append((entryID: entryID, jpdbRank: jpdbRank, wordfreqZipf: wordfreqZipf))

            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        return items
    }

    // Fetches one entry header by ID so callers can rebuild full entry payloads deterministically.
    private func fetchEntryHeader(entryID: Int64) throws -> (entryID: Int64, jpdbRank: Int?, wordfreqZipf: Double?)? {
        let sql = """
        SELECT e.id, MIN(wf.jpdb_rank), MAX(wf.wordfreq_zipf)
        FROM entries e
        LEFT JOIN word_frequency wf ON wf.entry_id = e.id
        WHERE e.id = ?1
        GROUP BY e.id
        LIMIT 1
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        try bindInt64(entryID, index: 1, statement: statement)

        let stepCode = sqlite3_step(statement)
        if stepCode == SQLITE_DONE {
            return nil
        }

        guard stepCode == SQLITE_ROW else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        let resolvedEntryID = sqlite3_column_int64(statement, 0)
        let jpdbRank = sqlite3_column_type(statement, 1) != SQLITE_NULL
            ? Int(sqlite3_column_int(statement, 1))
            : nil
        let wordfreqZipf = sqlite3_column_type(statement, 2) != SQLITE_NULL
            ? sqlite3_column_double(statement, 2)
            : nil

        let completionCode = sqlite3_step(statement)
        guard completionCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        return (entryID: resolvedEntryID, jpdbRank: jpdbRank, wordfreqZipf: wordfreqZipf)
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
        LEFT JOIN glosses g ON g.sense_id = s.id
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

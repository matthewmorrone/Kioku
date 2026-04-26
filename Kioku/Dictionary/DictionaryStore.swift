import Foundation
import SQLite3

nonisolated public final class DictionaryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    // Sentinel destructor value that tells SQLite to copy the string immediately.
    let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
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
    // Internal so extension files in other sources can wrap their queries in the same serial queue.
    func withSerializedDatabaseAccess<T>(_ operation: () throws -> T) rethrows -> T {
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

    // Resolves the canonical entry id for a surface without fetching kanji forms, kana forms, or
    // senses. Use when callers only need the stable identifier (e.g. saving a word, batched
    // identity resolution): cuts out the per-match form/sense fetches that lookup(surface:mode:)
    // performs, which is a 5–10× speedup since those three fetches dominate per-surface cost.
    // Selection priority matches lookup(surface:mode:) so the resolved id is identical to what
    // an interactive tap would produce — saved-word identity stays consistent across paths.
    public func lookupFirstEntryID(surface: String) throws -> Int64? {
        try withSerializedDatabaseAccess {
            for candidate in lookupSurfaces(for: surface) {
                if let header = try fetchMatchedEntries(surface: candidate, matchKana: true, matchKanji: true).first {
                    return header.entryID
                }
            }
            return nil
        }
    }

    // Batch resolves canonical entry ids for many surfaces in one SQL round trip — collapses N
    // serialized per-surface queries into a single query, the dominant cost of bulk save flows
    // (Add All Visible Words, segment-list prewarm). Each input surface is matched against its
    // primary trimmed form only; surfaces that need halfwidth/kyujitai/iteration-mark expansion
    // fall back to lookupFirstEntryID below so the final map is still complete. Returned ids
    // match lookupFirstEntryID's selection priority (jpdb rank → sense order → entry id), so
    // saved-word identity is consistent regardless of the path.
    public func lookupFirstEntryIDs(surfaces: [String]) throws -> [String: Int64] {
        guard surfaces.isEmpty == false else { return [:] }
        // Dedupe + drop empties so the bound parameter list matches the index space.
        var uniqueSurfaces: [String] = []
        var seen = Set<String>()
        for surface in surfaces {
            let trimmed = surface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, seen.insert(trimmed).inserted else { continue }
            uniqueSurfaces.append(trimmed)
        }
        guard uniqueSurfaces.isEmpty == false else { return [:] }

        return try withSerializedDatabaseAccess {
            var resolved: [String: Int64] = [:]
            // SQLite has a default SQLITE_LIMIT_VARIABLE_NUMBER (often 999); chunk to stay safely
            // under that even after the per-surface bind multiplier (1 here, since q_text alone
            // is bound). 256 keeps headroom and limits per-query memory pressure.
            let chunkSize = 256
            var index = uniqueSurfaces.startIndex
            while index < uniqueSurfaces.endIndex {
                let chunkEnd = uniqueSurfaces.index(index, offsetBy: chunkSize, limitedBy: uniqueSurfaces.endIndex) ?? uniqueSurfaces.endIndex
                let chunk = Array(uniqueSurfaces[index..<chunkEnd])
                try resolveChunk(chunk, into: &resolved)
                index = chunkEnd
            }
            // Fall back to per-surface lookup (with its full candidate-form expansion) for any
            // surface the batch query missed — covers halfwidth-only kana, kyujitai, iteration
            // marks, etc. Misses are typically a small minority so per-call cost stays bounded.
            for surface in uniqueSurfaces where resolved[surface] == nil {
                if let entryID = try fetchFirstEntryIDWithExpansion(for: surface) {
                    resolved[surface] = entryID
                }
            }
            return resolved
        }
    }

    // Runs the batch SQL for one chunk of surfaces. Builds a (idx, surface) inline VALUES list,
    // joins it against entries via the same kanji/kana EXISTS subqueries the per-surface path
    // uses, and picks the top entry per surface using the same priority (jpdb rank → sense order
    // → entry id) so id selection matches lookupFirstEntryID exactly.
    private func resolveChunk(_ surfaces: [String], into resolved: inout [String: Int64]) throws {
        let valuesList = (0..<surfaces.count).map { _ in "(?, ?)" }.joined(separator: ", ")
        let sql = """
        WITH q(idx, surface) AS (VALUES \(valuesList)),
             m AS (
                 SELECT q.idx, e.id AS entry_id,
                        MIN(wf.jpdb_rank) AS rank,
                        COALESCE(MIN(s.order_index), 2147483647) AS min_sense
                 FROM q
                 JOIN entries e ON EXISTS (
                     SELECT 1 FROM kanji kj WHERE kj.entry_id = e.id AND kj.text = q.surface
                     UNION ALL
                     SELECT 1 FROM kana_forms kf WHERE kf.entry_id = e.id AND kf.text = q.surface
                 )
                 LEFT JOIN word_frequency wf ON wf.entry_id = e.id
                     AND (EXISTS (SELECT 1 FROM kana_forms kf2 WHERE kf2.id = wf.kana_id AND kf2.text = q.surface)
                       OR EXISTS (SELECT 1 FROM kanji kj2 WHERE kj2.id = wf.kanji_id AND kj2.text = q.surface))
                 LEFT JOIN senses s ON s.entry_id = e.id
                 GROUP BY q.idx, e.id
             ),
             ranked AS (
                 SELECT idx, entry_id,
                        ROW_NUMBER() OVER (
                            PARTITION BY idx
                            ORDER BY COALESCE(rank, 9999999) ASC, min_sense ASC, entry_id ASC
                        ) AS rn
                 FROM m
             )
        SELECT idx, entry_id FROM ranked WHERE rn = 1
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        for (offset, surface) in surfaces.enumerated() {
            try bindInt64(Int64(offset), index: Int32(offset * 2 + 1), statement: statement)
            try bindText(surface, index: Int32(offset * 2 + 2), statement: statement)
        }

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            let idx = Int(sqlite3_column_int64(statement, 0))
            let entryID = sqlite3_column_int64(statement, 1)
            if idx >= 0, idx < surfaces.count {
                resolved[surfaces[idx]] = entryID
            }
            stepCode = sqlite3_step(statement)
        }
        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }
    }

    // Per-surface fallback used by the batch path when the primary form misses — runs the same
    // candidate expansion (halfwidth, iteration marks, kyujitai) lookupFirstEntryID does, but
    // without re-acquiring the access queue (caller already holds it).
    private func fetchFirstEntryIDWithExpansion(for surface: String) throws -> Int64? {
        for candidate in lookupSurfaces(for: surface) {
            if let header = try fetchMatchedEntries(surface: candidate, matchKana: true, matchKanji: true).first {
                return header.entryID
            }
        }
        return nil
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
            let matchedSurface = kanjiForms.first?.text ?? kanaForms.first?.text ?? ""

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

        // Normalize halfwidth katakana (ｱｲｳ) to fullwidth (アイウ) so copied text from
        // legacy sources still resolves against JMdict's fullwidth-only entries.
        let fullwidthNormalized = trimmedSurface.applyingTransform(.fullwidthToHalfwidth, reverse: true)
        if let fullwidthNormalized, fullwidthNormalized != trimmedSurface,
           orderedSurfaces.contains(fullwidthNormalized) == false {
            orderedSurfaces.append(fullwidthNormalized)
        }

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
        // Constrain the frequency join to only consider readings that match the looked-up surface.
        // Without this, an entry like 鑑 (かがみ=rare, かんがみる=common) would sort by its best
        // rank across ALL readings, misrepresenting the frequency of the matched reading.
        let frequencyJoin: String
        if matchKana && matchKanji {
            whereClause = """
            EXISTS (
                SELECT 1 FROM kanji kj WHERE kj.entry_id = e.id AND kj.text = ?1
                UNION ALL
                SELECT 1 FROM kana_forms kf WHERE kf.entry_id = e.id AND kf.text = ?1
            )
            """
            frequencyJoin = """
            LEFT JOIN word_frequency wf ON wf.entry_id = e.id
                AND (EXISTS (SELECT 1 FROM kana_forms kf2 WHERE kf2.id = wf.kana_id AND kf2.text = ?1)
                  OR EXISTS (SELECT 1 FROM kanji kj2 WHERE kj2.id = wf.kanji_id AND kj2.text = ?1))
            """
        } else if matchKana {
            whereClause = "EXISTS (SELECT 1 FROM kana_forms kf WHERE kf.entry_id = e.id AND kf.text = ?1)"
            frequencyJoin = """
            LEFT JOIN word_frequency wf ON wf.entry_id = e.id
                AND EXISTS (SELECT 1 FROM kana_forms kf2 WHERE kf2.id = wf.kana_id AND kf2.text = ?1)
            """
        } else {
            whereClause = "EXISTS (SELECT 1 FROM kanji kj WHERE kj.entry_id = e.id AND kj.text = ?1)"
            frequencyJoin = """
            LEFT JOIN word_frequency wf ON wf.entry_id = e.id
                AND EXISTS (SELECT 1 FROM kanji kj2 WHERE kj2.id = wf.kanji_id AND kj2.text = ?1)
            """
        }

        let sql = """
        SELECT e.id,
               MIN(wf.jpdb_rank) AS best_jpdb,
               MAX(wf.wordfreq_zipf) AS best_zipf,
               COALESCE(MIN(s.order_index), 2147483647) AS min_sense
        FROM entries e
        \(frequencyJoin)
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

    // Fetches ordered kanji forms with priority and ke_inf info tags for one entry.
    private func fetchKanjiForms(entryID: Int64) throws -> [KanjiForm] {
        let sql = """
        SELECT text, priority, info
        FROM kanji
        WHERE entry_id = ?1
        ORDER BY text ASC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        try bindInt64(entryID, index: 1, statement: statement)

        var items: [KanjiForm] = []
        var seenTexts = Set<String>()

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            guard let textPointer = sqlite3_column_text(statement, 0) else {
                stepCode = sqlite3_step(statement)
                continue
            }

            let text = String(cString: textPointer)
            // Keep first-seen order to mirror SQL ordering while avoiding duplicates.
            if seenTexts.insert(text).inserted {
                let priority = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let info = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                items.append(KanjiForm(text: text, priority: priority, info: info))
            }

            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        return items
    }

    // Fetches ordered kana forms with priority, re_inf info tags, and nokanji flag for one entry.
    private func fetchKanaForms(entryID: Int64) throws -> [KanaForm] {
        let sql = """
        SELECT text, priority, info, re_nokanji
        FROM kana_forms
        WHERE entry_id = ?1
        ORDER BY text ASC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        try prepare(sql: sql, statement: &statement)
        try bindInt64(entryID, index: 1, statement: statement)

        var items: [KanaForm] = []
        var seenTexts = Set<String>()

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            guard let textPointer = sqlite3_column_text(statement, 0) else {
                stepCode = sqlite3_step(statement)
                continue
            }

            let text = String(cString: textPointer)
            // Keep first-seen order to mirror SQL ordering while avoiding duplicates.
            if seenTexts.insert(text).inserted {
                let priority = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let info = sqlite3_column_text(statement, 2).map { String(cString: $0) }
                let nokanji = sqlite3_column_int(statement, 3) != 0
                items.append(KanaForm(text: text, priority: priority, info: info, nokanji: nokanji))
            }

            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }

        return items
    }

    // Fetches senses and ordered glosses for one entry, including misc, field, and dialect tags.
    private func fetchSenses(entryID: Int64) throws -> [DictionaryEntrySense] {
        let sql = """
        SELECT s.id, s.pos, s.misc, s.field, s.dialect, g.gloss
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
        var currentMisc: String?
        var currentField: String?
        var currentDialect: String?
        var currentGlosses: [String] = []

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {

            let senseID = sqlite3_column_int64(statement, 0)
            let pos = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let misc = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let field = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let dialect = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let gloss = sqlite3_column_text(statement, 5).map { String(cString: $0) }

            if currentSenseID != senseID {
                // Flush the previous sense before starting the next grouped row set.
                if currentSenseID != nil {
                    senses.append(DictionaryEntrySense(
                        pos: currentPOS,
                        misc: currentMisc,
                        field: currentField,
                        dialect: currentDialect,
                        glosses: currentGlosses
                    ))
                }
                currentSenseID = senseID
                currentPOS = pos
                currentMisc = misc
                currentField = field
                currentDialect = dialect
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
            senses.append(DictionaryEntrySense(
                pos: currentPOS,
                misc: currentMisc,
                field: currentField,
                dialect: currentDialect,
                glosses: currentGlosses
            ))
        }

        return senses
    }

    // Drives a prepared statement to completion, calling readRow for each SQLITE_ROW result.
    // Returning nil from readRow skips a malformed row; throwing aborts and propagates the error.
    // Internal so extension files can reuse the same step/collect loop without repeating it.
    func stepRows<T>(statement: OpaquePointer?, _ readRow: (OpaquePointer) throws -> T?) throws -> [T] {
        var results: [T] = []
        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            if let stmt = statement, let value = try readRow(stmt) {
                results.append(value)
            }
            stepCode = sqlite3_step(statement)
        }
        guard stepCode == SQLITE_DONE else {
            throw DictionarySQLiteError.step(message: errorMessage())
        }
        return results
    }

    // Compiles SQL into a prepared statement bound to the active connection.
    // Internal so extension files can prepare their own queries through the same connection.
    func prepare(sql: String, statement: inout OpaquePointer?) throws {
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK else {
            throw DictionarySQLiteError.prepareStatement(sql: sql, message: errorMessage())
        }
    }

    // Binds a text parameter to a prepared statement index.
    // Internal so extension files can bind parameters for their own queries.
    func bindText(_ text: String, index: Int32, statement: OpaquePointer?) throws {
        let code = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
        guard code == SQLITE_OK else {
            throw DictionarySQLiteError.bindParameter(message: errorMessage())
        }
    }

    // Binds a 64-bit integer parameter to a prepared statement index.
    // Internal so extension files can bind parameters for their own queries.
    func bindInt64(_ value: Int64, index: Int32, statement: OpaquePointer?) throws {
        let code = sqlite3_bind_int64(statement, index, value)
        guard code == SQLITE_OK else {
            throw DictionarySQLiteError.bindParameter(message: errorMessage())
        }
    }

    // Reads the most recent sqlite error message from the active connection.
    // Internal so extension files can surface errors from their own queries.
    func errorMessage() -> String {
        guard let db else { return "Database is not available" }
        return String(cString: sqlite3_errmsg(db))
    }
}

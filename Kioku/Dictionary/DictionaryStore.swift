import Foundation
import SQLite3

// invariant-store-test-coverage: LexiconTests.swift
//
// Read-only by nature — DictionaryStore is the SQLite read layer for the bundled
// JMdict-derived database. Every query method it exposes (surface lookup, lemma resolution,
// entry/sense fetch, sentence pairs, kanji forms) is exercised end-to-end by LexiconTests
// against the real dictionary.sqlite. Writing a parallel DictionaryStoreTests would
// duplicate that coverage without adding signal.

nonisolated public final class DictionaryStore: @unchecked Sendable {
    private var db: OpaquePointer?
    // Sentinel destructor value that tells SQLite to copy the string immediately.
    let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let accessQueue = DispatchQueue(label: "Kioku.DictionaryStore.sqlite.access")

    // Surface → canonical entry id map, populated once at app start by
    // populateCanonicalEntryIDMap() and read-only thereafter. Lookups that previously
    // required per-surface SQL (lookupFirstEntryID, lookupFirstEntryIDs) are now
    // hashtable hits over this map after Swift-side variant expansion.
    var canonicalEntryIDMap: [String: Int64] = [:]

    // Surface → OR-ed POS bits across every sense of every entry that has this surface
    // as either a kanji form or a kana form. Populated once at app start by
    // populateSurfacePOSBitsMap() and read-only thereafter. Lets Lexicon's deinflection
    // pruning (admittedLemmasAndPaths, compoundVerbComponents) run entirely in-memory
    // instead of issuing SQL per candidate. Memory cost is tiny (~8 bytes per entry
    // plus the shared keys with canonicalEntryIDMap).
    var surfacePOSBitsMap: [String: UInt64] = [:]

    // entry_id → JLPT level (5 = N5 easiest … 1 = N1 hardest). Populated once at app start by
    // populateJLPTLevelMap() and read-only thereafter; entries with no JLPT level are absent.
    // Backs the in-memory jlptLevel(for:) used by the Words filter and study-mode pickers, so
    // per-saved-word level checks are hashtable hits rather than SQL. See DictionaryStore+JLPT.
    var jlptLevelMap: [Int64: Int] = [:]

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

    // Resolves the canonical entry id for a surface as a pure in-memory lookup. Variant
    // expansion (halfwidth katakana, iteration marks, kyujitai) happens in Swift via
    // lookupSurfaces; each candidate is then a hashtable hit on canonicalEntryIDMap, which
    // is populated once at app start. Selection priority is encoded in the map at build
    // time (jpdb rank → sense order → entry id) so the resolved id matches what an
    // interactive lookup(surface:mode:) call would produce.
    public func lookupFirstEntryID(surface: String) -> Int64? {
        for candidate in lookupSurfaces(for: surface) {
            if let entryID = canonicalEntryIDMap[candidate] {
                return entryID
            }
        }
        return nil
    }

    // Batch variant of lookupFirstEntryID — preserved for callers that prefer a map result.
    // Now a tight Swift loop over canonicalEntryIDMap; the previous SQL batch + per-surface
    // fallback storm that dominated Add All latency is gone.
    public func lookupFirstEntryIDs(surfaces: [String]) -> [String: Int64] {
        guard surfaces.isEmpty == false else { return [:] }
        var resolved: [String: Int64] = [:]
        resolved.reserveCapacity(surfaces.count)
        for surface in surfaces {
            let trimmed = surface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, resolved[trimmed] == nil else { continue }
            if let entryID = lookupFirstEntryID(surface: trimmed) {
                resolved[trimmed] = entryID
            }
        }
        return resolved
    }

    // Batched materialization: fetches every facet (header, kanji forms, kana forms, senses,
    // glosses) for N entries in a SINGLE SQL statement via UNION ALL. Reassembles the rows
    // into [DictionaryEntry] in the original order of `entryIDs`. Replaces the per-entry
    // lookupEntry hot path that fired 4N round-trips through the serialized SQLite queue.
    nonisolated public func lookupEntries(entryIDs: [Int64]) throws -> [DictionaryEntry] {
        guard entryIDs.isEmpty == false else { return [] }
        return try withSerializedDatabaseAccess {
            // Unique IDs to bind once (callers may pass duplicates after multi-mode dedup).
            // Original order is preserved for the final result via the index map below.
            var orderMap: [Int64: Int] = [:]
            var unique: [Int64] = []
            for id in entryIDs where orderMap[id] == nil {
                orderMap[id] = unique.count
                unique.append(id)
            }

            // Single prepared statement with four UNION ALL legs. Each leg emits a row
            // tagged with row_kind ('h' header, 'k' kanji, 'r' kana, 's' sense-or-gloss).
            // All shared columns are projected as NULL where they don't apply so the column
            // shape matches across legs.
            let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
            let sql = """
            SELECT 'h' AS row_kind, e.id AS entry_id,
                   MIN(wf.jpdb_rank) AS jpdb_rank, MAX(wf.wordfreq_zipf) AS wordfreq_zipf,
                   NULL AS text, NULL AS priority, NULL AS info, NULL AS nokanji,
                   NULL AS sense_id, NULL AS pos, NULL AS misc, NULL AS field, NULL AS dialect,
                   NULL AS gloss, NULL AS sort_a, NULL AS sort_b
              FROM entries e
              LEFT JOIN word_frequency wf ON wf.entry_id = e.id
             WHERE e.id IN (\(placeholders))
             GROUP BY e.id
            UNION ALL
            SELECT 'k', k.entry_id, NULL, NULL,
                   k.text, k.priority, k.info, NULL,
                   NULL, NULL, NULL, NULL, NULL,
                   NULL, k.id, NULL
              FROM kanji k
             WHERE k.entry_id IN (\(placeholders))
            UNION ALL
            SELECT 'r', kf.entry_id, NULL, NULL,
                   kf.text, kf.priority, kf.info, kf.re_nokanji,
                   NULL, NULL, NULL, NULL, NULL,
                   NULL, kf.id, NULL
              FROM kana_forms kf
             WHERE kf.entry_id IN (\(placeholders))
            UNION ALL
            SELECT 's', s.entry_id, NULL, NULL,
                   NULL, NULL, NULL, NULL,
                   s.id, s.pos, s.misc, s.field, s.dialect,
                   g.gloss, s.order_index, g.order_index
              FROM senses s
              LEFT JOIN glosses g ON g.sense_id = s.id
             WHERE s.entry_id IN (\(placeholders))
            -- Within each entry, force a deterministic per-leg ordering so the first
            -- kanji/kana/sense is the JMdict-canonical primary form. Without this UNION ALL
            -- returns rows in arbitrary order and the "first kana form" picked into the
            -- entry's `kanaForms` array becomes whichever variant SQLite served first.
            ORDER BY entry_id ASC, row_kind ASC, sort_a ASC, sort_b ASC
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(sql: sql, statement: &statement)

            // The same ID list is bound four times — once per IN clause leg.
            var bindIndex: Int32 = 1
            for _ in 0..<4 {
                for id in unique {
                    try bindInt64(id, index: bindIndex, statement: statement)
                    bindIndex += 1
                }
            }

            // Mutable per-entry assembly state, keyed by entry_id.
            struct Assembly {
                var jpdbRank: Int?
                var wordfreqZipf: Double?
                // Order-preserving but dedup'd via the seen sets.
                var kanji: [KanjiForm] = []
                var kana: [KanaForm] = []
                var seenKanji = Set<String>()
                var seenKana = Set<String>()
                // Sense id → (sense fields, gloss list); senses ordered by emission order
                // which mirrors `s.order_index ASC` because the rows arrive in that order
                // within the 's' leg of the UNION.
                var senseOrder: [Int64] = []
                var senseFields: [Int64: (pos: String?, misc: String?, field: String?, dialect: String?)] = [:]
                var glossesBySense: [Int64: [String]] = [:]
                var seenGlossesBySense: [Int64: Set<String>] = [:]
            }
            var assembly: [Int64: Assembly] = [:]

            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                guard let kindPtr = sqlite3_column_text(statement, 0) else {
                    stepCode = sqlite3_step(statement); continue
                }
                let kind = String(cString: kindPtr)
                let entryID = sqlite3_column_int64(statement, 1)
                var entry = assembly[entryID] ?? Assembly()

                switch kind {
                case "h":
                    entry.jpdbRank = sqlite3_column_type(statement, 2) != SQLITE_NULL
                        ? Int(sqlite3_column_int(statement, 2)) : nil
                    entry.wordfreqZipf = sqlite3_column_type(statement, 3) != SQLITE_NULL
                        ? sqlite3_column_double(statement, 3) : nil
                case "k":
                    if let textPtr = sqlite3_column_text(statement, 4) {
                        let text = String(cString: textPtr)
                        if entry.seenKanji.insert(text).inserted {
                            let priority = sqlite3_column_text(statement, 5).map { String(cString: $0) }
                            let info = sqlite3_column_text(statement, 6).map { String(cString: $0) }
                            entry.kanji.append(KanjiForm(text: text, priority: priority, info: info))
                        }
                    }
                case "r":
                    if let textPtr = sqlite3_column_text(statement, 4) {
                        let text = String(cString: textPtr)
                        if entry.seenKana.insert(text).inserted {
                            let priority = sqlite3_column_text(statement, 5).map { String(cString: $0) }
                            let info = sqlite3_column_text(statement, 6).map { String(cString: $0) }
                            let nokanji = sqlite3_column_int(statement, 7) != 0
                            entry.kana.append(KanaForm(text: text, priority: priority, info: info, nokanji: nokanji))
                        }
                    }
                case "s":
                    let senseID = sqlite3_column_int64(statement, 8)
                    if entry.senseFields[senseID] == nil {
                        let pos = sqlite3_column_text(statement, 9).map { String(cString: $0) }
                        let misc = sqlite3_column_text(statement, 10).map { String(cString: $0) }
                        let field = sqlite3_column_text(statement, 11).map { String(cString: $0) }
                        let dialect = sqlite3_column_text(statement, 12).map { String(cString: $0) }
                        entry.senseFields[senseID] = (pos: pos, misc: misc, field: field, dialect: dialect)
                        entry.senseOrder.append(senseID)
                    }
                    if let glossPtr = sqlite3_column_text(statement, 13) {
                        let gloss = String(cString: glossPtr)
                        var seen = entry.seenGlossesBySense[senseID] ?? Set()
                        if seen.insert(gloss).inserted {
                            entry.seenGlossesBySense[senseID] = seen
                            entry.glossesBySense[senseID, default: []].append(gloss)
                        }
                    }
                default:
                    break
                }

                assembly[entryID] = entry
                stepCode = sqlite3_step(statement)
            }

            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: errorMessage())
            }

            // Build DictionaryEntry list in the order the caller requested.
            var result: [DictionaryEntry] = []
            result.reserveCapacity(unique.count)
            for entryID in unique {
                guard let a = assembly[entryID] else { continue }
                let senses = a.senseOrder.map { sid -> DictionaryEntrySense in
                    let fields = a.senseFields[sid] ?? (pos: nil, misc: nil, field: nil, dialect: nil)
                    return DictionaryEntrySense(
                        senseID: sid,
                        pos: fields.pos,
                        misc: fields.misc,
                        field: fields.field,
                        dialect: fields.dialect,
                        glosses: a.glossesBySense[sid] ?? [],
                        applicableKanji: [],
                        applicableReadings: []
                    )
                }
                let matchedSurface = a.kanji.first?.text ?? a.kana.first?.text ?? ""
                result.append(DictionaryEntry(
                    entryId: entryID,
                    jpdbRank: a.jpdbRank,
                    wordfreqZipf: a.wordfreqZipf,
                    matchedSurface: matchedSurface,
                    kanjiForms: a.kanji,
                    kanaForms: a.kana,
                    senses: senses
                ))
            }
            return result
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

        // Preserve the per-surface SQL ordering (which already encodes the kana-only-first
        // tier and the zipf fallback for missing JPDB ranks). A previous version piped these
        // through an unordered Dictionary and then re-sorted by jpdb_rank alone — silently
        // discarding both tiers, so a kana surface like "も" would return 藻 (jpdb=26345)
        // before the topic-particle entry (jpdb=nil → Int.max) despite the SQL ranking the
        // particle first. We dedupe but keep first-seen order.
        var matchedEntriesByID: [Int64: (jpdbRank: Int?, wordfreqZipf: Double?, matchedSurface: String)] = [:]
        var orderedEntryIDs: [Int64] = []

        for surface in surfaces {
            let matchedEntries = try fetchMatchedEntries(surface: surface, matchKana: matchKana, matchKanji: matchKanji)
            for header in matchedEntries {
                if matchedEntriesByID[header.entryID] == nil {
                    matchedEntriesByID[header.entryID] = (
                        jpdbRank: header.jpdbRank,
                        wordfreqZipf: header.wordfreqZipf,
                        matchedSurface: surface
                    )
                    orderedEntryIDs.append(header.entryID)
                }
            }
        }

        let matchedEntries = orderedEntryIDs.compactMap { entryID -> (entryID: Int64, jpdbRank: Int?, wordfreqZipf: Double?, matchedSurface: String)? in
            guard let value = matchedEntriesByID[entryID] else { return nil }
            return (entryID: entryID, jpdbRank: value.jpdbRank, wordfreqZipf: value.wordfreqZipf, matchedSurface: value.matchedSurface)
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
    // can resolve through standard dictionary queries. Internal so the canonical-id
    // extension can reuse the same expansion when probing the in-memory map.
    func lookupSurfaces(for surface: String) -> [String] {
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

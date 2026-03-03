import XCTest
import SQLite3
import Kioku

final class DictionaryLookupTests: XCTestCase {

    // MARK: - Behavioral Tests

    // Verifies kana-only mode requires exact kana form matches in observable results.
    func testKanaOnlyRequiresMatchingKanaForm() throws {
        let store = try makeStore()
        let surface = "ひかる"

        let results = try store.lookup(surface: surface, mode: .kanaOnly)

        XCTAssertFalse(results.isEmpty, "Expected kana-only lookup to return entries for \(surface).")
        for entry in results {
            XCTAssertTrue(
                entry.kanaForms.contains(surface),
                "Kana-only lookup returned entry \(entry.entryId) without exact kana form \(surface)."
            )
        }
    }

    // Verifies kanji-and-kana mode can return entries matching the exact kanji surface.
    func testKanjiLookupAllowsKanjiMatches() throws {
        let store = try makeStore()
        let surface = "光る"

        let results = try store.lookup(surface: surface, mode: .kanjiAndKana)

        XCTAssertTrue(
            results.contains(where: { $0.kanjiForms.contains(surface) }),
            "Expected at least one entry with kanji form \(surface) in kanjiAndKana mode."
        )
    }

    // Verifies lookup deduplicates entries by entry ID at the API boundary.
    func testNoDuplicateEntryIDs() throws {
        let store = try makeStore()

        let results = try store.lookup(surface: "みる", mode: .kanjiAndKana)
        let ids = results.map(\.entryId)

        XCTAssertEqual(
            Set(ids).count,
            ids.count,
            "Duplicate entry IDs detected; lookup must return distinct entries by entry.id."
        )
    }

    // Verifies common entries appear before non-common entries in returned ordering.
    func testCommonEntriesRankFirstBehaviorally() throws {
        let store = try makeStore()

        let results = try store.lookup(surface: "する", mode: .kanjiAndKana)
        XCTAssertFalse(results.isEmpty, "Expected entries for ranking verification.")

        var seenNonCommon = false
        for entry in results {
            if !entry.isCommon {
                seenNonCommon = true
            }

            if seenNonCommon {
                XCTAssertFalse(
                    entry.isCommon,
                    "Found common entry \(entry.entryId) after non-common entries; ranking contract broke."
                )
            }
        }
    }

    // Verifies unknown surfaces resolve to an empty result set.
    func testNonexistentSurfaceReturnsEmpty() throws {
        let store = try makeStore()

        let results = try store.lookup(surface: "🛸🛸🛸", mode: .kanjiAndKana)
        XCTAssertTrue(results.isEmpty, "Expected no entries for nonexistent surface.")
    }

    // MARK: - Database Contract Tests

    // Verifies sense ordering mirrors senses.order_index ASC from sqlite.
    func testSensesAreReturnedInDatabaseOrder() throws {
        let store = try makeStore()
        let results = try store.lookup(surface: "みる", mode: .kanjiAndKana)

        guard let entry = results.first else {
            XCTFail("Expected at least one entry to verify sense ordering.")
            return
        }

        let expected = try loadExpectedSensesAndGlosses(entryID: entry.entryId)
        let actualPOS = entry.senses.map { $0.pos ?? "" }
        let expectedPOS = expected.map { $0.pos ?? "" }

        XCTAssertEqual(
            actualPOS,
            expectedPOS,
            "Sense ordering mismatch for entry \(entry.entryId); expected sqlite senses.order_index ASC ordering."
        )
    }

    // Verifies gloss ordering mirrors glosses.order_index ASC from sqlite.
    func testGlossesAreReturnedInDatabaseOrder() throws {
        let store = try makeStore()
        let results = try store.lookup(surface: "みる", mode: .kanjiAndKana)

        guard let entry = results.first else {
            XCTFail("Expected at least one entry to verify gloss ordering.")
            return
        }

        let expected = try loadExpectedSensesAndGlosses(entryID: entry.entryId)

        XCTAssertEqual(
            entry.senses.count,
            expected.count,
            "Sense count mismatch while validating gloss ordering for entry \(entry.entryId)."
        )

        for index in entry.senses.indices {
            XCTAssertEqual(
                entry.senses[index].glosses,
                expected[index].glosses,
                "Gloss ordering mismatch for entry \(entry.entryId), sense index \(index)."
            )
        }
    }

    // Verifies entry ordering mirrors sqlite contract: is_common DESC then sense.order_index ASC.
    func testEntryOrderingMatchesDatabaseContract() throws {
        let store = try makeStore()
        let surface = "する"

        let results = try store.lookup(surface: surface, mode: .kanjiAndKana)
        let expectedIDs = try loadExpectedEntryOrdering(surface: surface, mode: .kanjiAndKana)
        let actualIDs = results.map(\.entryId)

        XCTAssertEqual(
            actualIDs,
            expectedIDs,
            "Entry ordering mismatch for \(surface); expected sqlite ordering by is_common DESC then senses.order_index ASC."
        )
    }

    // MARK: - Test Utilities

    // Creates a dictionary store bound to the real sqlite file used by the app.
    private func makeStore() throws -> DictionaryStore {
        try DictionaryStore(databaseURL: dictionaryDatabaseURL())
    }

    // Resolves dictionary.sqlite from the repository-level Resources directory.
    private func dictionaryDatabaseURL() throws -> URL {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let databaseURL = repositoryRoot.appendingPathComponent("Resources").appendingPathComponent("dictionary.sqlite")

        let exists = FileManager.default.fileExists(atPath: databaseURL.path)
        if !exists {
            throw NSError(
                domain: "DictionaryLookupTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "dictionary.sqlite not found at \(databaseURL.path)"]
            )
        }

        return databaseURL
    }

    // Reads expected sense and gloss ordering from sqlite for one entry.
    private func loadExpectedSensesAndGlosses(entryID: Int64) throws -> [(pos: String?, glosses: [String])] {
        let databaseURL = try dictionaryDatabaseURL()
        var db: OpaquePointer?

        let openCode = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown sqlite open error"
            sqlite3_close(db)
            throw NSError(domain: "DictionaryLookupTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_close(db) }

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

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DictionaryLookupTests",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

        guard sqlite3_bind_int64(statement, 1, entryID) == SQLITE_OK else {
            throw NSError(
                domain: "DictionaryLookupTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

        var rows: [(pos: String?, glosses: [String])] = []
        var currentSenseID: Int64?
        var currentPOS: String?
        var currentGlosses: [String] = []

        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            let senseID = sqlite3_column_int64(statement, 0)
            let pos = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let gloss = sqlite3_column_text(statement, 2).map { String(cString: $0) }

            if currentSenseID != senseID {
                // Flushes the previous ordered sense before collecting the next one.
                if currentSenseID != nil {
                    rows.append((pos: currentPOS, glosses: currentGlosses))
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
            throw NSError(
                domain: "DictionaryLookupTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

        // Flushes the final ordered sense after stepping completes.
        if currentSenseID != nil {
            rows.append((pos: currentPOS, glosses: currentGlosses))
        }

        return rows
    }

    // Reads expected entry ID ordering from sqlite for a given surface and lookup mode.
    private func loadExpectedEntryOrdering(surface: String, mode: LookupMode) throws -> [Int64] {
        let databaseURL = try dictionaryDatabaseURL()
        var db: OpaquePointer?

        let openCode = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openCode == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown sqlite open error"
            sqlite3_close(db)
            throw NSError(domain: "DictionaryLookupTests", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT e.id
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

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(
                domain: "DictionaryLookupTests",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

          guard sqlite3_bind_int(statement, 1, 1) == SQLITE_OK,
              sqlite3_bind_int(statement, 2, mode.matchKanji ? 1 : 0) == SQLITE_OK,
              sqlite3_bind_text(statement, 3, surface, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK
        else {
            throw NSError(
                domain: "DictionaryLookupTests",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

        var ids: [Int64] = []
        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            ids.append(sqlite3_column_int64(statement, 0))
            stepCode = sqlite3_step(statement)
        }

        guard stepCode == SQLITE_DONE else {
            throw NSError(
                domain: "DictionaryLookupTests",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
            )
        }

        return ids
    }
}

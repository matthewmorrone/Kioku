import XCTest
import SQLite3
@testable import Kioku

// Shared by every canonical-id-vs-live-ranking test below: a surface's script content alone
// determines which fetchMatchedEntries mode reproduces the ranking surface_canonical_entry was
// precomputed under (matchKana && !matchKanji for kana-only text, matchKanji-only otherwise) —
// mirrors lookupExactKana/lookupExactKanji's own mode flags.
private func liveTopEntryID(for surface: String, store: DictionaryStore) throws -> Int64? {
    let isPureKana = surface.unicodeScalars.allSatisfy { scalar in
        (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
    }
    let liveEntries = try store.withSerializedDatabaseAccess {
        try store.fetchMatchedEntries(surface: surface, matchKana: isPureKana, matchKanji: !isPureKana)
    }
    return liveEntries.first?.entryID
}

final class DictionaryDownloadManagerTests: XCTestCase {
    func testInstalledDatabaseURLPointsUnderApplicationSupportDictionary() {
        let url = DictionaryDownloadManager.installedDatabaseURL
        XCTAssertEqual(url.lastPathComponent, "dictionary.sqlite")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Dictionary")
    }

    func testSHA256OfFileMatchesKnownDigest() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kioku-sha256-test-\(UUID().uuidString).txt")
        try "hello world\n".data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let digest = try DictionaryDownloadManager.sha256(ofFileAt: tempURL)
        XCTAssertEqual(digest, "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447")
    }

    // Guards against a fix that's committed locally but never actually reaches a device:
    // dictionary.sqlite is downloaded from a pinned GitHub Release (DictionaryDownloadManager
    // never re-checks it unless releaseTag/expectedSHA256 change), so regenerating the local
    // file without bumping those two constants and publishing a new release leaves every
    // install — old and fresh — silently stuck on stale data forever. This exact gap shipped
    // in 065090a. If this test fails, publish a new GitHub Release and bump
    // DictionaryDownloadManager.releaseTag/expectedSHA256 (and Resources/data_manifest.json's
    // dictionary entry) to match — see docs/superpowers/plans/2026-07-15-dictionary-offload.md Task 6.
    func testLocalDictionarySQLiteMatchesPinnedRelease() throws {
        let digest = try DictionaryDownloadManager.sha256(ofFileAt: TestReadResources.dictionaryDatabaseURL())
        XCTAssertEqual(
            digest, DictionaryDownloadManager.expectedSHA256,
            "Resources/dictionary.sqlite doesn't match the pinned release hash — publish a new GitHub Release and bump releaseTag/expectedSHA256 before merging."
        )
    }

    // Spot-checks that the precomputed canonical-id map (surface_canonical_entry, read by
    // lookupFirstEntryID(s) — the path saved-word resolution uses) agrees with the live-ranked
    // fetchMatchedEntries query (used by interactive search/lookup) on which entry wins for a
    // given surface. The two are meant to encode the identical selection priority, but they're
    // two independent implementations — this Swift SQL query and generate_db.py's
    // materialize_canonical_entry_ids — kept in sync only by convention, so nothing but this test
    // stops a future change to one ranking tier from silently diverging from the other. Surfaces
    // below are the documented homophone/homograph collisions from DictionaryStore+RowFetching.swift
    // and DictionaryStore+FrequencyRanking.swift's own comments, plus a couple of ordinary words.
    func testCanonicalEntryIDMapAgreesWithLiveRanking() throws {
        let store = try DictionaryStore(databaseURL: TestReadResources.dictionaryDatabaseURL())
        try store.populateCanonicalEntryIDMap()

        let surfaces = ["あなた", "は", "も", "その", "この", "あの", "二人", "一人", "日", "食べる"]

        for surface in surfaces {
            XCTAssertEqual(
                store.canonicalEntryIDMap[surface], try liveTopEntryID(for: surface, store: store),
                "surface_canonical_entry disagrees with live ranking for '\(surface)' — regenerate dictionary.sqlite (materialize_canonical_entry_ids) so the two implementations stay in lockstep."
            )
        }
    }

    // Exhaustive version of the test above: every surface with more than one candidate entry —
    // the only surfaces where ranking choice is even possible, ~17k of dictionary.sqlite's ~456k
    // total surfaces as of this writing — not just the handful of collisions someone happened to
    // notice and hand-pick. A single-candidate surface can't disagree with itself, so this is
    // already complete coverage of every surface where the two implementations COULD diverge,
    // without paying to iterate the ~439k surfaces where they trivially can't. This is also the
    // harness to run before and after any future consolidation of the two ranking implementations
    // (see the session note on unifying fetchMatchedEntries and materialize_canonical_entry_ids):
    // diff its failures against the pre-change baseline to prove a rewritten ranking query is
    // actually equivalent, not just "looks right" on a hand-picked sample.
    func testCanonicalEntryIDMapAgreesWithLiveRankingForEveryAmbiguousSurface() throws {
        let store = try DictionaryStore(databaseURL: TestReadResources.dictionaryDatabaseURL())
        try store.populateCanonicalEntryIDMap()

        let ambiguousSurfaces = try store.withSerializedDatabaseAccess { () -> [String] in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try store.prepare(
                sql: """
                SELECT text FROM (
                    SELECT text, entry_id FROM kanji
                    UNION
                    SELECT text, entry_id FROM kana_forms
                )
                GROUP BY text
                HAVING COUNT(DISTINCT entry_id) > 1
                """,
                statement: &statement
            )
            var surfaces: [String] = []
            var stepCode = sqlite3_step(statement)
            while stepCode == SQLITE_ROW {
                if let textPointer = sqlite3_column_text(statement, 0) {
                    surfaces.append(String(cString: textPointer))
                }
                stepCode = sqlite3_step(statement)
            }
            guard stepCode == SQLITE_DONE else {
                throw DictionarySQLiteError.step(message: store.errorMessage())
            }
            return surfaces
        }
        XCTAssertFalse(ambiguousSurfaces.isEmpty, "query for ambiguous surfaces returned nothing — likely a broken test query, not a dictionary with zero homophones")

        var mismatches: [String] = []
        for surface in ambiguousSurfaces {
            if store.canonicalEntryIDMap[surface] != (try liveTopEntryID(for: surface, store: store)) {
                mismatches.append(surface)
            }
        }

        XCTAssertTrue(
            mismatches.isEmpty,
            "surface_canonical_entry disagrees with live ranking for \(mismatches.count) of \(ambiguousSurfaces.count) ambiguous surfaces: "
                + mismatches.prefix(20).joined(separator: ", ") + (mismatches.count > 20 ? ", …" : "")
                + " — regenerate dictionary.sqlite so the two implementations stay in lockstep."
        )
    }

    // Ground-truth check, independent of whether the two ranking implementations agree with EACH
    // OTHER: testCanonicalEntryIDMapAgreesWithLiveRanking* above would pass even if both
    // implementations made the identical mistake (e.g. a bug copied forward while porting one to
    // match the other during a future consolidation). This instead asserts the actual expected
    // headword/gloss for surfaces that have shipped wrong before — real answers, verified directly
    // against dictionary.sqlite, not just internal self-consistency.
    func testKnownCollisionSurfacesResolveToTheCorrectEntry() throws {
        let store = try DictionaryStore(databaseURL: TestReadResources.dictionaryDatabaseURL())
        try store.populateCanonicalEntryIDMap()

        // (surface, expected first kanji form or nil for a kana-only entry, a gloss substring
        // that must appear somewhere in the entry's senses)
        let expectations: [(surface: String, expectedKanji: String?, expectedGlossSubstring: String)] = [
            ("あなた", "貴方", "you"),       // was resolving to 彼方 "beyond, across, the other side" — the bug this session fixed
            ("は", nil, "topic"),            // topic particle; must not resolve to 派 "faction"
            ("も", nil, "too"),
            ("その", nil, "that"),           // demonstrative; must not resolve to 園 "garden"
            ("二人", "二人", "two"),
        ]

        for expectation in expectations {
            guard let entryID = store.canonicalEntryIDMap[expectation.surface] else {
                XCTFail("no canonical entry resolved for '\(expectation.surface)'")
                continue
            }
            guard let entry = try store.lookupEntry(entryID: entryID) else {
                XCTFail("canonical entry \(entryID) for '\(expectation.surface)' failed to load")
                continue
            }
            if let expectedKanji = expectation.expectedKanji {
                XCTAssertEqual(
                    entry.kanjiForms.first?.text, expectedKanji,
                    "surface '\(expectation.surface)' resolved to the wrong headword"
                )
            }
            let allGlosses = entry.senses.flatMap(\.glosses).joined(separator: " ").lowercased()
            XCTAssertTrue(
                allGlosses.contains(expectation.expectedGlossSubstring),
                "surface '\(expectation.surface)' resolved to an entry without expected gloss '\(expectation.expectedGlossSubstring)' — got: \(allGlosses)"
            )
        }
    }

    // Exercises DictionaryStore's no-arg init against whatever the real Application Support
    // state is: if a dictionary happens to already be installed (e.g. a prior manual test run),
    // opening it should succeed; if not, it must throw .databaseNotFound rather than crash or
    // hang. Both branches are asserted so the test is meaningful either way, without touching or
    // deleting real on-disk state.
    func testDictionaryStoreThrowsDatabaseNotFoundWhenNotInstalled() {
        do {
            _ = try DictionaryStore()
            XCTAssertTrue(DictionaryDownloadManager.isInstalled, "DictionaryStore() succeeded but isInstalled is false")
        } catch DictionarySQLiteError.databaseNotFound(let name) {
            XCTAssertEqual(name, "dictionary.sqlite")
            XCTAssertFalse(DictionaryDownloadManager.isInstalled)
        } catch {
            XCTFail("expected .databaseNotFound, got \(error)")
        }
    }
}

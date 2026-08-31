import XCTest
@testable import Kioku

// Characterizes DictionaryStore.fetchDistractorPool — the dictionary-wide supplement Multiple
// Choice merges behind the learner's own saved-word pool so a thin saved pool doesn't force weak,
// guessable distractors.
@MainActor
final class DictionaryStoreDistractorPoolTests: XCTestCase {
    var store: DictionaryStore!

    override func setUpWithError() throws {
        store = try DictionaryStore(databaseURL: TestReadResources.dictionaryDatabaseURL())
    }

    func testFetchDistractorPoolReturnsEverydayWordsWithAtLeastOneScriptForm() throws {
        let rows = try store.fetchDistractorPool(limit: 500)

        XCTAssertFalse(rows.isEmpty)
        XCTAssertLessThanOrEqual(rows.count, 500)
        for row in rows {
            XCTAssertTrue(row.kanji != nil || row.kana != nil, "every row supplies at least one script form")
        }
    }

    // No row's kanji form is tagged rare/outdated/irregular/search-only (rK/oK/iK/sK) — verified
    // against the real dictionary by re-looking up each surfaced kanji spelling and checking its
    // own JMdict info tag with the same rule `DictionaryEntry.firstEverydayKanji` uses, rather than
    // asserting against one hardcoded example: JMdict's rK/oK/iK/sK tagging is sparse enough that a
    // word which merely *reads* as rare isn't reliably tagged as such in the data.
    func testDistractorPoolNeverSurfacesNonEverydayKanji() throws {
        let rows = try store.fetchDistractorPool(limit: 300)
        XCTAssertFalse(rows.isEmpty)

        for row in rows {
            guard let kanjiText = row.kanji else { continue }
            let entries = try store.lookup(surface: kanjiText, mode: .kanjiAndKana)
            let matchingForm = entries.compactMap { $0.kanjiForms.first { $0.text == kanjiText } }.first
            let info = matchingForm?.info
            XCTAssertFalse(
                DictionaryEntry.kanjiFormIsNonEveryday(info: info),
                "\(kanjiText) is tagged non-everyday (\(info ?? "nil")) but still surfaced in the distractor pool"
            )
        }
    }
}

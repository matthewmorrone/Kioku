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

    // たゆたう's only kanji form (揺蕩う) is tagged rK — the exact word this whole fix started
    // from (see WordFormResolverTests). It must never surface as a distractor pool's kanji form,
    // even with a generous limit, since a learner could never plausibly recognize it.
    func testDistractorPoolNeverSurfacesNonEverydayKanji() throws {
        let rows = try store.fetchDistractorPool(limit: 3000)
        XCTAssertFalse(rows.contains { $0.kanji == "揺蕩う" })
    }
}

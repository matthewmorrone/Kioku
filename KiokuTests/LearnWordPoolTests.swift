import XCTest
@testable import Kioku

// Characterizes LearnWordPool.resolveItems' hasKanjiForm/kanji resolution — the gate Multiple
// Choice and Fill in the Blank use to decide whether a word can be asked a 漢字 direction at all.
@MainActor
final class LearnWordPoolTests: XCTestCase {
    var store: DictionaryStore!

    override func setUpWithError() throws {
        store = try DictionaryStore(databaseURL: TestReadResources.dictionaryDatabaseURL())
    }

    // A word saved in kana (surface has no kanji) must never resolve a kanji field or count as
    // having a kanji form, even when its dictionary entry has a common, everyday kanji spelling —
    // the learner never saved the word that way, so it must never be quizzed on it.
    func testKanaOnlySurfaceNeverResolvesKanji() async throws {
        let entries = try store.lookup(surface: "食べる", mode: .kanjiAndKana)
        let entry = try XCTUnwrap(entries.first)
        let word = SavedWord(canonicalEntryID: entry.entryId, surface: "たべる")

        let items = await LearnWordPool.resolveItems(for: [word], dictionaryStore: store)
        let item = try XCTUnwrap(items.first)

        XCTAssertNil(item.kanji)
        XCTAssertFalse(item.hasKanjiForm)
    }

    // A word saved with its kanji surface still resolves a kanji field and counts as having a
    // kanji form — the surface gate only withholds kanji the learner never actually saved.
    func testKanjiSurfaceStillResolvesKanji() async throws {
        let entries = try store.lookup(surface: "食べる", mode: .kanjiAndKana)
        let entry = try XCTUnwrap(entries.first)
        let word = SavedWord(canonicalEntryID: entry.entryId, surface: "食べる")

        let items = await LearnWordPool.resolveItems(for: [word], dictionaryStore: store)
        let item = try XCTUnwrap(items.first)

        XCTAssertTrue(item.hasKanjiForm)
    }
}

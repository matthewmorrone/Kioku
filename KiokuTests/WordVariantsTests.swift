import XCTest
@testable import Kioku

// Characterization tests for WordVariants.alternateSpellings — the helper that
// powers the "Variants" section in WordDetailView. Each test pins one behavior:
// kanji surfaces surface alternate kanji + kana, kana surfaces stay empty (the
// "false uniqueness" guard), and archaic/search-only forms are filtered out by
// their JMdict info tag.
final class WordVariantsTests: XCTestCase {

    // Helpers to build minimal entries without dragging the real DictionaryStore in.

    private func kanji(_ text: String, info: String? = nil) -> KanjiForm {
        KanjiForm(text: text, priority: nil, info: info)
    }

    private func kana(_ text: String, info: String? = nil) -> KanaForm {
        KanaForm(text: text, priority: nil, info: info, nokanji: false)
    }

    private func entry(kanji: [KanjiForm], kana: [KanaForm]) -> DictionaryEntry {
        DictionaryEntry(
            entryId: 1,
            jpdbRank: nil,
            wordfreqZipf: nil,
            matchedSurface: kanji.first?.text ?? kana.first?.text ?? "",
            kanjiForms: kanji,
            kanaForms: kana,
            senses: []
        )
    }

    // Saved surface is a kanji form; entry has one other kanji + one kana.
    // Expect both alternates surfaced (combined list has 2 items, passes the
    // non-empty threshold).
    func testSurfacesBothKanjiAndKanaAlternatesForKanjiSurface() {
        let e = entry(
            kanji: [kanji("抱く"), kanji("懐く")],
            kana:  [kana("いだく"), kana("だく")]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["懐く", "いだく", "だく"]))
    }

    // Saved surface is a kanji form; entry has only one kana variant. The
    // previous "only when count > 1" gate would have hidden this, but now that
    // we also include kanji variants we surface single alternates too.
    func testSurfacesSoloKanjiAlternateForKanjiSurface() {
        let e = entry(
            kanji: [kanji("抱く"), kanji("懐く")],
            kana:  [kana("だく")]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["懐く", "だく"]))
    }

    // Saved surface is pure kana. JMdict's kana → kanji mapping is many-to-one
    // for a kana reading, so showing kanji forms here implies a false
    // uniqueness. Keep the guard from the original implementation.
    func testReturnsEmptyForKanaSurface() {
        let e = entry(
            kanji: [kanji("抱く"), kanji("懐く")],
            kana:  [kana("だく")]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "だく", entry: e)
        XCTAssertEqual(result, [])
    }

    // Archaic kana forms (re_inf "ok") and search-only kana forms (re_inf "sk")
    // are dictionary noise; existing kana filter excluded them. Same for kanji:
    // out-dated kanji ("oK") and search-only kanji ("sK") should not surface.
    func testExcludesArchaicAndSearchOnlyForms() {
        let e = entry(
            kanji: [
                kanji("抱く"),
                kanji("懐く"),                      // keep
                kanji("古抱く", info: "oK"),         // drop (out-dated kanji)
                kanji("検抱く", info: "sK"),         // drop (search-only kanji)
            ],
            kana: [
                kana("だく"),                        // keep
                kana("いだく"),                      // keep
                kana("ふるだく", info: "ok"),        // drop (out-dated kana)
                kana("けんだく", info: "sk"),        // drop (search-only kana)
            ]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["懐く", "だく", "いだく"]))
    }

    // Irregular kanji ("iK") and irregular kana ("ik") are legitimate writings
    // that the user might encounter and want to recognize. Keep them.
    func testKeepsIrregularForms() {
        let e = entry(
            kanji: [kanji("抱く"), kanji("懐く", info: "iK")],
            kana:  [kana("だく", info: "ik")]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["懐く", "だく"]))
    }

    // An entry with no real alternates beyond the saved surface returns empty,
    // not a list containing the saved surface or stray empties.
    func testReturnsEmptyWhenNoAlternates() {
        let e = entry(
            kanji: [kanji("抱く")],
            kana:  []
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(result, [])
    }
}

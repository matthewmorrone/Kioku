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

    // Saved surface is a kanji form; entry has one other kanji + two kana forms.
    // The first kana form (いだく) is the entry's primary reading — already shown
    // as the headword's reading elsewhere on screen, not a distinct spelling —
    // so only the second kana form (だく) surfaces alongside the kanji alternate.
    func testSurfacesKanjiAlternateAndSecondaryKanaForKanjiSurface() {
        let e = entry(
            kanji: [kanji("抱く"), kanji("懐く")],
            kana:  [kana("いだく"), kana("だく")]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["懐く", "だく"]))
    }

    // Saved surface is a kanji form; entry has only one kana form (its primary
    // reading), which is excluded as just the headword's own reading restated —
    // so only the kanji alternate surfaces.
    func testSurfacesSoloKanjiAlternateForKanjiSurface() {
        let e = entry(
            kanji: [kanji("抱く"), kanji("懐く")],
            kana:  [kana("だく")]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["懐く"]))
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
    // だく is the entry's primary (first) kana form, so it's excluded as the
    // headword's own reading regardless of the archaic/search-only filter.
    func testExcludesArchaicAndSearchOnlyForms() {
        let e = entry(
            kanji: [
                kanji("抱く"),
                kanji("懐く"),                      // keep
                kanji("古抱く", info: "oK"),         // drop (out-dated kanji)
                kanji("検抱く", info: "sK"),         // drop (search-only kanji)
            ],
            kana: [
                kana("だく"),                        // drop (primary reading, not an alternate)
                kana("いだく"),                      // keep
                kana("ふるだく", info: "ok"),        // drop (out-dated kana)
                kana("けんだく", info: "sk"),        // drop (search-only kana)
            ]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["懐く", "いだく"]))
    }

    // Irregular kanji ("iK") and irregular kana ("ik") are legitimate writings
    // that the user might encounter and want to recognize. Keep them. The
    // irregular kana form here is the entry's SECOND kana form specifically —
    // the first (primary reading) is always dropped regardless of its info tag,
    // so a single-kana-form entry couldn't demonstrate this rule on its own.
    func testKeepsIrregularForms() {
        let e = entry(
            kanji: [kanji("抱く"), kanji("懐く", info: "iK")],
            kana:  [kana("だく"), kana("いだく", info: "ik")]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["懐く", "いだく"]))
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

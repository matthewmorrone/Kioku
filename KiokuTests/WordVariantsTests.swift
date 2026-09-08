import XCTest
@testable import Kioku

// Characterization tests for WordVariants.alternateSpellings and .otherReadings — the helpers
// that power the "Also Written As" and "Other Readings" sections in WordDetailView. Each test
// pins one behavior: kanji surfaces surface alternate kanji / other kana readings separately,
// kana surfaces stay empty for both (the "false uniqueness" guard), and archaic/search-only
// forms are filtered out by their JMdict info tag.
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

    // Saved surface is a kanji form; entry has one other kanji + two kana forms. The first kana
    // form (いだく) is the entry's primary reading — already shown as the headword's reading
    // elsewhere on screen, not a distinct spelling or reading — so alternateSpellings surfaces
    // just the kanji alternate, and otherReadings surfaces just the second kana form.
    func testSurfacesKanjiAlternateForKanjiSurface() {
        let e = entry(
            kanji: [kanji("抱く"), kanji("懐く")],
            kana:  [kana("いだく"), kana("だく")]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["懐く"]))
    }

    func testSurfacesSecondaryKanaAsOtherReadingForKanjiSurface() {
        let e = entry(
            kanji: [kanji("抱く"), kanji("懐く")],
            kana:  [kana("いだく"), kana("だく")]
        )
        let result = WordVariants.otherReadings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["だく"]))
    }

    // Saved surface is a kanji form; entry has only one kana form (its primary
    // reading), which is excluded as just the headword's own reading restated —
    // so only the kanji alternate surfaces, and otherReadings is empty.
    func testSurfacesSoloKanjiAlternateForKanjiSurface() {
        let e = entry(
            kanji: [kanji("抱く"), kanji("懐く")],
            kana:  [kana("だく")]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["懐く"]))
        XCTAssertEqual(WordVariants.otherReadings(savedSurface: "抱く", entry: e), [])
    }

    // Saved surface is pure kana. JMdict's kana → kanji mapping is many-to-one
    // for a kana reading, so showing kanji forms (or other readings) here
    // implies a false uniqueness. Keep the guard from the original implementation,
    // for both helpers.
    func testReturnsEmptyForKanaSurface() {
        let e = entry(
            kanji: [kanji("抱く"), kanji("懐く")],
            kana:  [kana("だく")]
        )
        XCTAssertEqual(WordVariants.alternateSpellings(savedSurface: "だく", entry: e), [])
        XCTAssertEqual(WordVariants.otherReadings(savedSurface: "だく", entry: e), [])
    }

    // Archaic kanji ("oK") and search-only kanji ("sK") are dictionary noise and
    // should not surface as alternate spellings.
    func testAlternateSpellingsExcludesArchaicAndSearchOnlyKanji() {
        let e = entry(
            kanji: [
                kanji("抱く"),
                kanji("懐く"),                      // keep
                kanji("古抱く", info: "oK"),         // drop (out-dated kanji)
                kanji("検抱く", info: "sK"),         // drop (search-only kanji)
            ],
            kana: [kana("だく")]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["懐く"]))
    }

    // Archaic kana forms (re_inf "ok") and search-only kana forms (re_inf "sk")
    // are dictionary noise and should not surface as other readings. だく is the
    // entry's primary (first) kana form, so it's excluded as the headword's own
    // reading regardless of the archaic/search-only filter.
    func testOtherReadingsExcludesArchaicAndSearchOnlyKana() {
        let e = entry(
            kanji: [kanji("抱く")],
            kana: [
                kana("だく"),                        // drop (primary reading, not an alternate)
                kana("いだく"),                      // keep
                kana("ふるだく", info: "ok"),        // drop (out-dated kana)
                kana("けんだく", info: "sk"),        // drop (search-only kana)
            ]
        )
        let result = WordVariants.otherReadings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(result, ["いだく"])
    }

    // Irregular kanji ("iK") is a legitimate writing the user might encounter and
    // want to recognize. Keep it.
    func testAlternateSpellingsKeepsIrregularKanji() {
        let e = entry(
            kanji: [kanji("抱く"), kanji("懐く", info: "iK")],
            kana:  [kana("だく")]
        )
        let result = WordVariants.alternateSpellings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(Set(result), Set(["懐く"]))
    }

    // Irregular kana ("ik") is a legitimate reading the user might encounter and
    // want to recognize. Keep it. This is the entry's SECOND kana form
    // specifically — the first (primary reading) is always dropped regardless
    // of its info tag, so a single-kana-form entry couldn't demonstrate this
    // rule on its own.
    func testOtherReadingsKeepsIrregularKana() {
        let e = entry(
            kanji: [kanji("抱く")],
            kana:  [kana("だく"), kana("いだく", info: "ik")]
        )
        let result = WordVariants.otherReadings(savedSurface: "抱く", entry: e)
        XCTAssertEqual(result, ["いだく"])
    }

    // An entry with no real alternates beyond the saved surface returns empty for
    // both helpers, not a list containing the saved surface or stray empties.
    func testReturnsEmptyWhenNoAlternates() {
        let e = entry(
            kanji: [kanji("抱く")],
            kana:  []
        )
        XCTAssertEqual(WordVariants.alternateSpellings(savedSurface: "抱く", entry: e), [])
        XCTAssertEqual(WordVariants.otherReadings(savedSurface: "抱く", entry: e), [])
    }
}

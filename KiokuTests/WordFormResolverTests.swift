import XCTest
@testable import Kioku

// Characterizes WordFormResolver — the shared kanji/kana computation every quiz/study view now
// uses, factored out of FlashcardCard/MultipleChoiceView/FlashcardTypedAnswerControl/FillInBlankView.
@MainActor
final class WordFormResolverTests: XCTestCase {
    var store: DictionaryStore!

    override func setUpWithError() throws {
        store = try DictionaryStore(databaseURL: TestReadResources.dictionaryDatabaseURL())
    }

    // kanjiAndKana(entry:) returns the entry's kanji headword and the first kana form when no
    // senses/glosses are selected — matches the pre-refactor behavior at every call site.
    func testKanjiAndKanaWithNoSelection() throws {
        let entries = try store.lookup(surface: "学校", mode: .kanjiAndKana)
        let entry = try XCTUnwrap(entries.first)

        let forms = WordFormResolver.kanjiAndKana(
            entry: entry, store: store, entryID: entry.entryId, selectedSenseIDs: [], selectedGlosses: []
        )

        XCTAssertEqual(forms.kanji, entry.firstEverydayKanji?.text)
        XCTAssertEqual(forms.kana, entry.kanaForms.first?.text)
    }

    // A word that's usually written in kana but has a rare kanji form (たゆたう / 揺蕩う, tagged
    // rK) must not be quizzed on that spelling — kanji resolves to nil, same as a word with no
    // kanji form at all, rather than falling back to the rare headword.
    func testKanjiAndKanaOmitsNonEverydayKanji() throws {
        let entries = try store.lookup(surface: "たゆたう", mode: .kanjiAndKana)
        let entry = try XCTUnwrap(entries.first(where: { $0.kanjiForms.contains { $0.text == "揺蕩う" } }))

        let forms = WordFormResolver.kanjiAndKana(
            entry: entry, store: store, entryID: entry.entryId, selectedSenseIDs: [], selectedGlosses: []
        )

        XCTAssertNil(forms.kanji)
    }

    // A sense-restricted reading (黄昏's dusk/twilight sense → たそがれ, not the alphabetically
    // first こうこん) is honored — same fixture/assertion as PreferredKanaTests, confirming the
    // shared helper preserves this behavior rather than just delegating blindly.
    func testKanjiAndKanaHonorsSenseRestriction() throws {
        let entries = try store.lookup(surface: "黄昏", mode: .kanjiAndKana)
        let entry = try XCTUnwrap(entries.first(where: { e in
            let kana = Set(e.kanaForms.map(\.text))
            return kana.contains("たそがれ") && kana.contains("こうこん")
        }), "Expected a 黄昏 entry carrying both readings in the bundled dictionary.")
        let duskSense = try XCTUnwrap(
            entry.senses.first(where: { sense in
                sense.glosses.contains(where: { $0.lowercased().contains("dusk") || $0.lowercased().contains("twilight") })
            })
        )

        let forms = WordFormResolver.kanjiAndKana(
            entry: entry, store: store, entryID: entry.entryId,
            selectedSenseIDs: [duskSense.senseID], selectedGlosses: []
        )

        XCTAssertEqual(forms.kana, "たそがれ")
    }

    // fetchKanjiAndKana (the fetch-then-compute convenience wrapper) returns the same kanji/kana
    // as calling kanjiAndKana directly against an entry fetched via fetchWordDisplayData.
    func testFetchKanjiAndKanaMatchesEntryBasedVariant() throws {
        let entries = try store.lookup(surface: "食べる", mode: .kanjiAndKana)
        let entry = try XCTUnwrap(entries.first)
        let data = try XCTUnwrap(try store.fetchWordDisplayData(entryID: entry.entryId, surface: "食べる"))

        let direct = WordFormResolver.kanjiAndKana(
            entry: data.entry, store: store, entryID: entry.entryId, selectedSenseIDs: [], selectedGlosses: []
        )
        let fetched = WordFormResolver.fetchKanjiAndKana(
            store: store, entryID: entry.entryId, surface: "食べる", selectedSenseIDs: [], selectedGlosses: []
        )

        XCTAssertEqual(fetched?.kanji, direct.kanji)
        XCTAssertEqual(fetched?.kana, direct.kana)
    }

    // fetchKanjiAndKana returns nil for an entry ID the dictionary doesn't have, without throwing
    // — mirrors fetchWordDisplayData's own nil-for-unknown-ID contract.
    func testFetchKanjiAndKanaReturnsNilForUnknownEntryID() {
        let forms = WordFormResolver.fetchKanjiAndKana(
            store: store, entryID: -1, surface: "x", selectedSenseIDs: [], selectedGlosses: []
        )
        XCTAssertNil(forms)
    }
}

import XCTest
@testable import Kioku

@MainActor
final class PreferredKanaTests: XCTestCase {
    var store: DictionaryStore!

    override func setUpWithError() throws {
        store = try DictionaryStore()
    }

    // 黄昏 has two kana readings: こうこん (alphabetically first) and たそがれ. The
    // "dusk/twilight" sense carries a stagr restriction limiting it to たそがれ. With that
    // sense selected, the flashcard reading must follow the restriction, not the alphabetic
    // first kana form.
    func testTasogareWinsWhenDuskSenseSelected() throws {
        let entries = try store.lookup(surface: "黄昏", mode: .kanjiAndKana)
        let entry = try XCTUnwrap(entries.first(where: { e in
            let kana = Set(e.kanaForms.map(\.text))
            return kana.contains("たそがれ") && kana.contains("こうこん")
        }), "Expected a 黄昏 entry carrying both readings in the bundled dictionary.")

        let duskSense = try XCTUnwrap(
            entry.senses.first(where: { sense in
                sense.glosses.contains(where: { $0.lowercased().contains("dusk") || $0.lowercased().contains("twilight") })
            }),
            "Expected a sense with a dusk/twilight gloss."
        )

        let restrictions = try store.fetchSenseRestrictions(entryID: entry.entryId)
        let result = entry.preferredKana(
            selectedSenseIDs: [duskSense.senseID],
            selectedGlosses: [],
            senseRestrictions: restrictions
        )

        XCTAssertEqual(result, "たそがれ")
    }

    // With no senses selected, behavior matches the pre-fix path: return the first kana form
    // in entry order so cards without selections aren't disturbed.
    func testFallsBackToFirstKanaWhenNothingSelected() throws {
        let entries = try store.lookup(surface: "黄昏", mode: .kanjiAndKana)
        let entry = try XCTUnwrap(entries.first(where: { e in
            let kana = Set(e.kanaForms.map(\.text))
            return kana.contains("たそがれ") && kana.contains("こうこん")
        }))

        let restrictions = try store.fetchSenseRestrictions(entryID: entry.entryId)
        let result = entry.preferredKana(
            selectedSenseIDs: [],
            selectedGlosses: [],
            senseRestrictions: restrictions
        )

        XCTAssertEqual(result, entry.kanaForms.first?.text)
    }

    // A gloss-level selection still resolves the owning sense's restrictions, so picking just
    // a gloss from the dusk/twilight sense produces the same reading as picking the sense.
    func testGlossRefAlsoApplyRestriction() throws {
        let entries = try store.lookup(surface: "黄昏", mode: .kanjiAndKana)
        let entry = try XCTUnwrap(entries.first(where: { e in
            let kana = Set(e.kanaForms.map(\.text))
            return kana.contains("たそがれ") && kana.contains("こうこん")
        }))
        let duskSense = try XCTUnwrap(
            entry.senses.first(where: { sense in
                sense.glosses.contains(where: { $0.lowercased().contains("dusk") || $0.lowercased().contains("twilight") })
            })
        )

        let restrictions = try store.fetchSenseRestrictions(entryID: entry.entryId)
        let result = entry.preferredKana(
            selectedSenseIDs: [],
            selectedGlosses: [GlossRef(senseID: duskSense.senseID, glossIndex: 0)],
            senseRestrictions: restrictions
        )

        XCTAssertEqual(result, "たそがれ")
    }
}

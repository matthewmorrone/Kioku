import XCTest
@testable import Kioku

final class RelatedWordsOrganizerTests: XCTestCase {

    // Builds a minimal entry with a single kanji headword and one sense carrying the given POS.
    private func entry(id: Int64, kanji: String, pos: String?) -> DictionaryEntry {
        DictionaryEntry(
            entryId: id,
            jpdbRank: nil,
            wordfreqZipf: nil,
            matchedSurface: kanji,
            kanjiForms: [KanjiForm(text: kanji, priority: nil, info: nil)],
            kanaForms: [],
            senses: [DictionaryEntrySense(senseID: id, pos: pos, misc: nil, field: nil, dialect: nil, glosses: ["x"])]
        )
    }

    // A transitive saved verb pins its intransitive same-skeleton partner to the front, tagged.
    func test_transitiveSaved_pinsIntransitiveCounterpartFirst() {
        let saved = entry(id: 1, kanji: "上げる", pos: "v1,vt")            // 上
        let counterpart = entry(id: 2, kanji: "上がる", pos: "v5r,vi")      // 上
        let unrelated = entry(id: 3, kanji: "上手", pos: "adj-na")          // 上 + 手 → 上手 skeleton

        let result = RelatedWordsOrganizer.partition(saved: saved, related: [unrelated, counterpart])

        XCTAssertEqual(result.structural.map(\.entry.entryId), [2])
        XCTAssertEqual(result.structural.first?.relation, .intransitiveCounterpart)
        XCTAssertEqual(result.others.map(\.entryId), [3])
    }

    // An intransitive saved verb surfaces its transitive partner with the mirrored label.
    func test_intransitiveSaved_pinsTransitiveCounterpartFirst() {
        let saved = entry(id: 1, kanji: "出る", pos: "v1,vi")             // 出
        let counterpart = entry(id: 2, kanji: "出す", pos: "v5s,vt")       // 出

        let result = RelatedWordsOrganizer.partition(saved: saved, related: [counterpart])

        XCTAssertEqual(result.structural.first?.relation, .transitiveCounterpart)
        XCTAssertTrue(result.others.isEmpty)
    }

    // Counterparts are emitted ahead of plain same-stem forms regardless of input order.
    func test_counterpartsOrderedBeforeOtherSameStemForms() {
        let saved = entry(id: 1, kanji: "上げる", pos: "v1,vt")
        let nominalized = entry(id: 2, kanji: "上げ", pos: "n")            // same 上 skeleton, not a counterpart
        let counterpart = entry(id: 3, kanji: "上がる", pos: "v5r,vi")

        let result = RelatedWordsOrganizer.partition(saved: saved, related: [nominalized, counterpart])

        XCTAssertEqual(result.structural.map(\.entry.entryId), [3, 2])
        XCTAssertEqual(result.structural.map(\.relation), [.intransitiveCounterpart, .sameStemForm])
    }

    // Entries that only share the primary kanji (different skeleton) stay in the general remainder.
    func test_differentSkeletonStaysInOthers() {
        let saved = entry(id: 1, kanji: "食事", pos: "n")                 // 食事
        let kanjiFamily = entry(id: 2, kanji: "食べる", pos: "v1,vt")      // 食 — shares 食 only

        let result = RelatedWordsOrganizer.partition(saved: saved, related: [kanjiFamily])

        XCTAssertTrue(result.structural.isEmpty)
        XCTAssertEqual(result.others.map(\.entryId), [2])
    }

    // A pure-kana saved word has no skeleton, so nothing is treated as structural.
    func test_kanaOnlySaved_yieldsNoStructuralGroup() {
        let saved = DictionaryEntry(
            entryId: 1, jpdbRank: nil, wordfreqZipf: nil, matchedSurface: "する",
            kanjiForms: [], kanaForms: [KanaForm(text: "する", priority: nil, info: nil, nokanji: false)],
            senses: [DictionaryEntrySense(senseID: 1, pos: "vs-i,vt", misc: nil, field: nil, dialect: nil, glosses: ["to do"])]
        )
        let other = entry(id: 2, kanji: "為る", pos: "vs-i,vt")

        let result = RelatedWordsOrganizer.partition(saved: saved, related: [other])

        XCTAssertTrue(result.structural.isEmpty)
        XCTAssertEqual(result.others.map(\.entryId), [2])
    }

    // Same skeleton but matching transitivity (both vt) is a same-stem form, not a counterpart.
    func test_sameTransitivity_isSameStemNotCounterpart() {
        let saved = entry(id: 1, kanji: "上げる", pos: "v1,vt")
        let alsoTransitive = entry(id: 2, kanji: "上げ", pos: "v1,vt")

        let result = RelatedWordsOrganizer.partition(saved: saved, related: [alsoTransitive])

        XCTAssertEqual(result.structural.first?.relation, .sameStemForm)
    }
}

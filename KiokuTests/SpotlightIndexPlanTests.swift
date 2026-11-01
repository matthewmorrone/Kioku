import XCTest
@testable import Kioku

// Pins the Spotlight identifier round-trip, document text, and the diff that decides what gets
// reindexed or removed — in particular that note changes never remove word results.
@MainActor
final class SpotlightIndexPlanTests: XCTestCase {
    private func doc(_ id: SpotlightIdentifier, title: String = "t") -> SpotlightDocument {
        SpotlightDocument(identifier: id, title: title, summary: "", keywords: [], bodyText: nil, modifiedAt: nil)
    }

    func testIdentifierRoundTrips() {
        let note = SpotlightIdentifier.note(id: UUID())
        XCTAssertEqual(SpotlightIdentifier(rawValue: note.rawValue), note)
        let word = SpotlightIdentifier.word(entryID: 1_234_567)
        XCTAssertEqual(SpotlightIdentifier(rawValue: word.rawValue), word)
        XCTAssertNil(SpotlightIdentifier(rawValue: "other:1"))
        XCTAssertNil(SpotlightIdentifier(rawValue: "note:not-a-uuid"))
    }

    func testPlanIndexesOnlyChangedDocuments() {
        let a = doc(.word(entryID: 1))
        let b = doc(.word(entryID: 2), title: "old")
        let changedB = doc(.word(entryID: 2), title: "new")
        let plan = SpotlightIndexPlan.make(
            previous: [a.identifier: a, b.identifier: b],
            documents: [a, changedB],
            domains: [SpotlightIdentifier.wordDomain]
        )
        XCTAssertEqual(plan.upserts, [changedB])
        XCTAssertTrue(plan.removals.isEmpty)
    }

    func testDeletingNoteDoesNotRemoveSavedWords() {
        let noteID = UUID()
        let note = doc(.note(id: noteID))
        let word = doc(.word(entryID: 9))
        let plan = SpotlightIndexPlan.make(
            previous: [note.identifier: note, word.identifier: word],
            documents: [],
            domains: [SpotlightIdentifier.noteDomain]
        )
        XCTAssertEqual(plan.removals, [.note(id: noteID)])
    }

    func testNoteDocumentFlattensContentAndBoundsSummary() {
        let note = Note(title: "  ", content: "一行目\n\n二行目 " + String(repeating: "あ", count: 300))
        let document = SpotlightDocumentBuilder.document(for: note)
        XCTAssertEqual(document.title, "Untitled Note")
        XCTAssertTrue(document.summary.hasPrefix("一行目 二行目"))
        XCTAssertEqual(document.summary.count, SpotlightDocumentBuilder.summaryLimit)
    }

    func testWordDocumentCombinesReadingAndMeanings() {
        let word = SavedWord(canonicalEntryID: 42, surface: "食べる")
        let content = WordCardContent(surface: "食べる", kanji: "食べる", kana: "たべる", meanings: ["to eat", "to live on"])
        let document = SpotlightDocumentBuilder.document(for: word, content: content)
        XCTAssertEqual(document.identifier, .word(entryID: 42))
        XCTAssertEqual(document.summary, "たべる — to eat; to live on")
        XCTAssertTrue(document.keywords.contains("to eat"))
    }
}

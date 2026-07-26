import XCTest
@testable import Kioku

// Characterizes SentenceBlankResolver.findBlank — the reverse of Cloze's sentence-picking: given an
// already-known word, find a sentence in its source notes containing it.
final class SentenceBlankResolverTests: XCTestCase {

    func testFindsSentenceContainingSurface() {
        let noteID = UUID()
        let note = Note(id: noteID, content: "今日は晴れです。猫が窓の外を見ています。")
        let word = SavedWord(canonicalEntryID: 1, surface: "猫", sourceNoteIDs: [noteID])

        let blank = SentenceBlankResolver.findBlank(for: word, notes: [note])

        XCTAssertEqual(blank?.surface, "猫")
        XCTAssertEqual(blank?.before, "")
        XCTAssertEqual(blank?.after, "が窓の外を見ています。")
    }

    // The first sentence containing the surface wins, even when a later sentence also contains it.
    func testUsesFirstMatchingSentence() {
        let noteID = UUID()
        let note = Note(id: noteID, content: "猫は好きです。でも犬も猫も飼っています。")
        let word = SavedWord(canonicalEntryID: 1, surface: "猫", sourceNoteIDs: [noteID])

        let blank = SentenceBlankResolver.findBlank(for: word, notes: [note])

        XCTAssertEqual(blank?.before, "")
        XCTAssertEqual(blank?.after, "は好きです。")
    }

    // Checks source notes in sourceNoteIDs order, skipping ones that don't contain the surface.
    func testChecksSourceNotesInOrderAndSkipsNonMatches() {
        let firstID = UUID()
        let secondID = UUID()
        let first = Note(id: firstID, content: "天気がいいですね。")
        let second = Note(id: secondID, content: "本を読みました。")
        let word = SavedWord(canonicalEntryID: 1, surface: "本", sourceNoteIDs: [firstID, secondID])

        let blank = SentenceBlankResolver.findBlank(for: word, notes: [first, second])

        XCTAssertEqual(blank?.before, "")
        XCTAssertEqual(blank?.after, "を読みました。")
    }

    func testReturnsNilWhenNoSourceNoteContainsSurface() {
        let noteID = UUID()
        let note = Note(id: noteID, content: "天気がいいですね。")
        let word = SavedWord(canonicalEntryID: 1, surface: "猫", sourceNoteIDs: [noteID])

        XCTAssertNil(SentenceBlankResolver.findBlank(for: word, notes: [note]))
    }

    // A source note ID with no matching Note (deleted since the word was saved) is skipped, not
    // treated as an error.
    func testReturnsNilWhenSourceNoteIsMissing() {
        let word = SavedWord(canonicalEntryID: 1, surface: "猫", sourceNoteIDs: [UUID()])
        XCTAssertNil(SentenceBlankResolver.findBlank(for: word, notes: []))
    }

    func testReturnsNilWhenWordHasNoSourceNotes() {
        let word = SavedWord(canonicalEntryID: 1, surface: "猫", sourceNoteIDs: [])
        XCTAssertNil(SentenceBlankResolver.findBlank(for: word, notes: []))
    }
}

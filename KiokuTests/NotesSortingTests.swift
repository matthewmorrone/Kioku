import XCTest
@testable import Kioku

// Verifies the pure notes-list ordering: each field's comparison, direction flipping, stability
// on ties, and the unrated-notes-last rule for Difficulty.
final class NotesSortingTests: XCTestCase {

    private func note(
        _ title: String,
        content: String = "",
        created: TimeInterval = 0,
        modified: TimeInterval = 0
    ) -> Note {
        Note(
            title: title,
            content: content,
            createdAt: Date(timeIntervalSince1970: created),
            modifiedAt: Date(timeIntervalSince1970: modified)
        )
    }

    func testManualLeavesOrderUntouched() {
        let notes = [note("c"), note("a"), note("b")]
        let sorted = NotesSorting.sorted(notes, field: .manual, ascending: true)
        XCTAssertEqual(sorted.map(\.title), ["c", "a", "b"])
    }

    func testTitleSortsCaseInsensitivelyBothWays() {
        let notes = [note("banana"), note("Apple"), note("cherry")]
        XCTAssertEqual(
            NotesSorting.sorted(notes, field: .title, ascending: true).map(\.title),
            ["Apple", "banana", "cherry"]
        )
        XCTAssertEqual(
            NotesSorting.sorted(notes, field: .title, ascending: false).map(\.title),
            ["cherry", "banana", "Apple"]
        )
    }

    // An untitled note is filed under its first content line, matching the row's own display.
    func testUntitledNoteSortsByItsFirstContentLine() {
        let notes = [note("zebra"), note("", content: "apple pie\nmore text")]
        XCTAssertEqual(
            NotesSorting.sorted(notes, field: .title, ascending: true).map(NotesSorting.sortableTitle(for:)),
            ["apple pie", "zebra"]
        )
    }

    func testEmptyNoteFallsBackToUntitledLabel() {
        XCTAssertEqual(NotesSorting.sortableTitle(for: note("", content: "   \n ")), "Untitled Note")
    }

    func testDateModifiedDefaultsToNewestFirst() {
        let notes = [note("old", modified: 100), note("new", modified: 300), note("mid", modified: 200)]
        XCTAssertEqual(
            NotesSorting.sorted(notes, field: .dateModified, ascending: false).map(\.title),
            ["new", "mid", "old"]
        )
        XCTAssertEqual(
            NotesSorting.sorted(notes, field: .dateModified, ascending: true).map(\.title),
            ["old", "mid", "new"]
        )
    }

    func testDateCreatedIsIndependentOfModified() {
        let notes = [
            note("a", created: 300, modified: 1),
            note("b", created: 100, modified: 999)
        ]
        XCTAssertEqual(
            NotesSorting.sorted(notes, field: .dateCreated, ascending: false).map(\.title),
            ["a", "b"]
        )
    }

    func testLengthIgnoresSurroundingWhitespace() {
        let notes = [
            note("short", content: "あい"),
            note("long", content: "\n\n  あいうえお  \n"),
            note("mid", content: "あいう")
        ]
        XCTAssertEqual(NotesSorting.length(of: notes[1]), 5)
        XCTAssertEqual(
            NotesSorting.sorted(notes, field: .length, ascending: false).map(\.title),
            ["long", "mid", "short"]
        )
    }

    func testWordsToLearnUsesSuppliedMetrics() {
        let notes = [note("few"), note("many"), note("none")]
        let counts: [String: Int] = ["few": 3, "many": 9, "none": 0]
        let metrics: (Note) -> NoteSortMetrics = { NoteSortMetrics(wordsToLearn: counts[$0.title] ?? 0) }

        XCTAssertEqual(
            NotesSorting.sorted(notes, field: .wordsToLearn, ascending: false, metrics: metrics).map(\.title),
            ["many", "few", "none"]
        )
        XCTAssertEqual(
            NotesSorting.sorted(notes, field: .wordsToLearn, ascending: true, metrics: metrics).map(\.title),
            ["none", "few", "many"]
        )
    }

    // Notes with no JLPT-rated words sink to the bottom in both directions rather than being
    // treated as the easiest.
    func testDifficultyPutsUnratedNotesLastInBothDirections() {
        let notes = [note("unrated"), note("hard"), note("easy")]
        let scores: [String: Double?] = ["unrated": nil, "hard": 4.5, "easy": 1.0]
        let metrics: (Note) -> NoteSortMetrics = { NoteSortMetrics(difficulty: scores[$0.title] ?? nil) }

        XCTAssertEqual(
            NotesSorting.sorted(notes, field: .difficulty, ascending: false, metrics: metrics).map(\.title),
            ["hard", "easy", "unrated"]
        )
        XCTAssertEqual(
            NotesSorting.sorted(notes, field: .difficulty, ascending: true, metrics: metrics).map(\.title),
            ["easy", "hard", "unrated"]
        )
    }

    // Ties keep the notes' stored (manual) order so equal values don't shuffle between renders.
    func testTiesArePreservedInManualOrder() {
        let notes = [note("first", modified: 50), note("second", modified: 50), note("third", modified: 50)]
        XCTAssertEqual(
            NotesSorting.sorted(notes, field: .dateModified, ascending: false).map(\.title),
            ["first", "second", "third"]
        )
    }

    func testDefaultDirectionIsAscendingOnlyForTitle() {
        for field in NotesSortField.allCases {
            XCTAssertEqual(field.defaultAscending, field == .title, "\(field.rawValue)")
        }
    }
}

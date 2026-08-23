import XCTest
@testable import Kioku

// Verifies the pure notes-list ordering: every sort field's comparison, the per-field direction
// flip, untitled/tie handling, and that manual order is passed through untouched.
@MainActor
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

    func testManualOrderIsPassedThroughAndReversed() {
        let notes = [note("a"), note("b"), note("c")]
        XCTAssertEqual(NotesSorter.sorted(notes, field: .manual, ascending: true).map(\.title), ["a", "b", "c"])
        XCTAssertEqual(NotesSorter.sorted(notes, field: .manual, ascending: false).map(\.title), ["c", "b", "a"])
    }

    func testTitleSortIsCaseInsensitiveAndNumericAware() {
        let notes = [note("Lesson 10"), note("apple"), note("Lesson 2")]
        XCTAssertEqual(
            NotesSorter.sorted(notes, field: .title, ascending: true).map(\.title),
            ["apple", "Lesson 2", "Lesson 10"]
        )
        XCTAssertEqual(
            NotesSorter.sorted(notes, field: .title, ascending: false).map(\.title),
            ["Lesson 10", "Lesson 2", "apple"]
        )
    }

    // An untitled note falls back to its content; one with neither sorts last in an A→Z list so a
    // run of blank rows can't bury the named notes.
    func testUntitledNotesFallBackToContentThenSortLast() {
        let notes = [note("", content: ""), note("zebra"), note("", content: "alpha")]
        XCTAssertEqual(
            NotesSorter.sorted(notes, field: .title, ascending: true).map { "\($0.title)|\($0.content)" },
            ["|alpha", "zebra|", "|"]
        )
    }

    // The empty bucket is not part of the comparison, so reversing the direction must not float
    // blank rows to the top of a Z→A list.
    func testEmptyNotesStayLastInBothTitleDirections() {
        let notes = [note("", content: ""), note("zebra"), note("", content: "alpha")]
        XCTAssertEqual(
            NotesSorter.sorted(notes, field: .title, ascending: false).map { "\($0.title)|\($0.content)" },
            ["zebra|", "|alpha", "|"]
        )
    }

    func testDateSorts() {
        let notes = [
            note("old", created: 100, modified: 900),
            note("new", created: 300, modified: 100),
            note("mid", created: 200, modified: 500),
        ]
        XCTAssertEqual(NotesSorter.sorted(notes, field: .created, ascending: false).map(\.title), ["new", "mid", "old"])
        XCTAssertEqual(NotesSorter.sorted(notes, field: .created, ascending: true).map(\.title), ["old", "mid", "new"])
        XCTAssertEqual(NotesSorter.sorted(notes, field: .modified, ascending: false).map(\.title), ["old", "mid", "new"])
    }

    // Length counts trimmed characters, so leading/trailing whitespace can't inflate a note.
    func testLengthSortIgnoresSurroundingWhitespace() {
        let notes = [
            note("long", content: "あいうえおかきくけこ"),
            note("short", content: "   あい   "),
            note("medium", content: "あいうえお"),
        ]
        XCTAssertEqual(
            NotesSorter.sorted(notes, field: .length, ascending: true).map(\.title),
            ["short", "medium", "long"]
        )
    }

    func testKanjiDensityDrivesDifficulty() {
        XCTAssertEqual(NoteTextMetrics.kanjiDensity(of: "ひらがな"), 0, accuracy: 0.0001)
        XCTAssertEqual(NoteTextMetrics.kanjiDensity(of: "漢字"), 1, accuracy: 0.0001)
        // Whitespace is excluded from the denominator.
        XCTAssertEqual(NoteTextMetrics.kanjiDensity(of: "漢 字 か ら"), 0.5, accuracy: 0.0001)
        XCTAssertEqual(NoteTextMetrics.kanjiDensity(of: "   "), 0, accuracy: 0.0001)

        let notes = [
            note("mixed", content: "漢字かな"),
            note("kana", content: "かなだけ"),
            note("dense", content: "難読漢字"),
        ]
        XCTAssertEqual(
            NotesSorter.sorted(notes, field: .difficulty, ascending: true).map(\.title),
            ["kana", "mixed", "dense"]
        )
    }

    // Two notes the density can't separate order by length — the longer read is the harder one.
    func testEqualDifficultyBreaksTieOnLength() {
        let notes = [note("longer", content: "かなかなかな"), note("shorter", content: "かな")]
        XCTAssertEqual(
            NotesSorter.sorted(notes, field: .difficulty, ascending: true).map(\.title),
            ["shorter", "longer"]
        )
    }

    func testWordsToLearnSortUsesInjectedCounts() {
        let notes = [note("few"), note("many"), note("none")]
        let counts = [notes[0].id: 3, notes[1].id: 12]
        let metrics = NoteSortMetrics(wordsToLearn: { counts[$0.id] ?? 0 })

        XCTAssertEqual(
            NotesSorter.sorted(notes, field: .wordsToLearn, ascending: false, metrics: metrics).map(\.title),
            ["many", "few", "none"]
        )
        XCTAssertEqual(
            NotesSorter.sorted(notes, field: .wordsToLearn, ascending: true, metrics: metrics).map(\.title),
            ["none", "few", "many"]
        )
    }

    // Notes a field can't tell apart keep their incoming (manual) order in both directions —
    // Swift's sort isn't stable on its own, so this is the explicit tie-break doing the work.
    func testTiesPreserveIncomingOrder() {
        let notes = [note("first", modified: 5), note("second", modified: 5), note("third", modified: 5)]
        XCTAssertEqual(
            NotesSorter.sorted(notes, field: .modified, ascending: true).map(\.title),
            ["first", "second", "third"]
        )
        XCTAssertEqual(
            NotesSorter.sorted(notes, field: .modified, ascending: false).map(\.title),
            ["first", "second", "third"]
        )
    }

    func testDefaultDirectionsMatchFieldSemantics() {
        XCTAssertTrue(NotesSortField.title.defaultsToAscending)
        XCTAssertTrue(NotesSortField.length.defaultsToAscending)
        XCTAssertTrue(NotesSortField.difficulty.defaultsToAscending)
        XCTAssertFalse(NotesSortField.modified.defaultsToAscending)
        XCTAssertFalse(NotesSortField.created.defaultsToAscending)
        XCTAssertFalse(NotesSortField.wordsToLearn.defaultsToAscending)
    }
}

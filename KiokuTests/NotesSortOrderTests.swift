import XCTest
@testable import Kioku

// NotesSortOrder inherits the target's MainActor default isolation (SWIFT_DEFAULT_ACTOR_ISOLATION),
// so the whole case is annotated rather than hopping per assertion.
@MainActor
final class NotesSortOrderTests: XCTestCase {
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

    private func titles(_ notes: [Note]) -> [String] { notes.map(\.title) }

    func testManualPreservesStoredOrder() {
        let notes = [note("c"), note("a"), note("b")]
        XCTAssertEqual(titles(NotesSortOrder.sorted(notes, by: .manual)), ["c", "a", "b"])
    }

    func testTitleSorts() {
        let notes = [note("Banana"), note("apple"), note("Cherry")]
        XCTAssertEqual(titles(NotesSortOrder.sorted(notes, by: .titleAToZ)), ["apple", "Banana", "Cherry"])
        XCTAssertEqual(titles(NotesSortOrder.sorted(notes, by: .titleZToA)), ["Cherry", "Banana", "apple"])
    }

    func testUntitledNotesSortUnderTheirDisplayedTitle() {
        let notes = [note("Alpha"), note("   "), note("Zulu")]
        // "Untitled Note" lands between Alpha and Zulu, matching what the row renders.
        XCTAssertEqual(titles(NotesSortOrder.sorted(notes, by: .titleAToZ)), ["Alpha", "   ", "Zulu"])
    }

    func testCreatedAndModifiedSorts() {
        let notes = [
            note("mid", created: 200, modified: 50),
            note("old", created: 100, modified: 300),
            note("new", created: 300, modified: 100),
        ]
        XCTAssertEqual(titles(NotesSortOrder.sorted(notes, by: .newestCreated)), ["new", "mid", "old"])
        XCTAssertEqual(titles(NotesSortOrder.sorted(notes, by: .oldestCreated)), ["old", "mid", "new"])
        XCTAssertEqual(titles(NotesSortOrder.sorted(notes, by: .recentlyModified)), ["old", "new", "mid"])
        XCTAssertEqual(titles(NotesSortOrder.sorted(notes, by: .leastRecentlyModified)), ["mid", "new", "old"])
    }

    func testLengthSorts() {
        let notes = [note("b", content: "ああ"), note("a", content: "あ"), note("c", content: "あああ")]
        XCTAssertEqual(titles(NotesSortOrder.sorted(notes, by: .longest)), ["c", "b", "a"])
        XCTAssertEqual(titles(NotesSortOrder.sorted(notes, by: .shortest)), ["a", "b", "c"])
    }

    func testWordsLeftToLearnSorts() {
        let notes = [note("few"), note("many"), note("none")]
        let counts: [String: Int] = ["few": 2, "many": 9, "none": 0]
        let key: (Note) -> Int = { counts[$0.title] ?? 0 }
        XCTAssertEqual(
            titles(NotesSortOrder.sorted(notes, by: .mostWordsToLearn, wordsLeftToLearn: key)),
            ["many", "few", "none"]
        )
        XCTAssertEqual(
            titles(NotesSortOrder.sorted(notes, by: .fewestWordsToLearn, wordsLeftToLearn: key)),
            ["none", "few", "many"]
        )
    }

    func testTiesKeepManualOrder() {
        let notes = [note("first", created: 10), note("second", created: 10), note("third", created: 10)]
        XCTAssertEqual(titles(NotesSortOrder.sorted(notes, by: .newestCreated)), ["first", "second", "third"])
        XCTAssertEqual(titles(NotesSortOrder.sorted(notes, by: .oldestCreated)), ["first", "second", "third"])
    }

    func testSortingNeverDropsOrDuplicatesNotes() {
        let notes = (0..<8).map { note("n\($0)", content: String(repeating: "あ", count: $0 % 3), created: TimeInterval($0 % 4)) }
        for order in NotesSortOrder.allCases {
            let sorted = NotesSortOrder.sorted(notes, by: order) { $0.title.count % 2 }
            XCTAssertEqual(Set(sorted.map(\.id)), Set(notes.map(\.id)), "\(order.rawValue)")
            XCTAssertEqual(sorted.count, notes.count, "\(order.rawValue)")
        }
    }

    func testOnlyLearnCountOrdersNeedTheLearnCounts() {
        for order in NotesSortOrder.allCases {
            let expected = order == .mostWordsToLearn || order == .fewestWordsToLearn
            XCTAssertEqual(order.usesWordsLeftToLearn, expected, order.rawValue)
        }
    }

    func testEveryCaseHasATitleAndIcon() {
        for order in NotesSortOrder.allCases {
            XCTAssertFalse(order.title.isEmpty)
            XCTAssertFalse(order.systemImage.isEmpty)
        }
    }
}

import XCTest
@testable import Kioku

// Verifies the pure notes ordering: each sort key, its direction, stable tie-breaking on the
// stored (manual) position, and where notes with no difficulty signal land.
final class NotesSortingTests: XCTestCase {

    private func date(_ offsetDays: Double) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offsetDays * 86_400)
    }

    // a: created day 0, modified day 3, 10 chars; b: created day 1, modified day 1, 30 chars;
    // c: created day 2, modified day 2, 20 chars.
    private func sampleNotes() -> [Note] {
        [
            Note(title: "banana", content: String(repeating: "あ", count: 10), createdAt: date(0), modifiedAt: date(3)),
            Note(title: "Apple", content: String(repeating: "あ", count: 30), createdAt: date(1), modifiedAt: date(1)),
            Note(title: "", content: String(repeating: "あ", count: 20), createdAt: date(2), modifiedAt: date(2)),
        ]
    }

    private func metrics(_ notes: [Note]) -> (Note) -> NoteSortMetrics {
        let byID: [UUID: NoteSortMetrics] = [
            notes[0].id: NoteSortMetrics(length: 10, difficulty: 2, wordsLeftToLearn: 5),
            notes[1].id: NoteSortMetrics(length: 30, difficulty: 4, wordsLeftToLearn: 0),
            notes[2].id: NoteSortMetrics(length: 20, difficulty: nil, wordsLeftToLearn: 3),
        ]
        return { byID[$0.id] ?? NoteSortMetrics() }
    }

    private func titles(_ notes: [Note]) -> [String] {
        notes.map { $0.title.isEmpty ? "(untitled)" : $0.title }
    }

    func testManualOrderIsUntouched() {
        let notes = sampleNotes()
        XCTAssertEqual(NotesSorting.sorted(notes, by: .manual, metrics: metrics(notes)).map(\.id), notes.map(\.id))
    }

    // Case-insensitive, and a blank title sorts as "Untitled Note" rather than as an empty string.
    func testTitleSortIsCaseInsensitiveAndUsesUntitledFallback() {
        let notes = sampleNotes()
        XCTAssertEqual(titles(NotesSorting.sorted(notes, by: .titleAToZ, metrics: metrics(notes))), ["Apple", "banana", "(untitled)"])
        XCTAssertEqual(titles(NotesSorting.sorted(notes, by: .titleZToA, metrics: metrics(notes))), ["(untitled)", "banana", "Apple"])
    }

    func testDateSorts() {
        let notes = sampleNotes()
        XCTAssertEqual(titles(NotesSorting.sorted(notes, by: .recentlyModified, metrics: metrics(notes))), ["banana", "(untitled)", "Apple"])
        XCTAssertEqual(titles(NotesSorting.sorted(notes, by: .leastRecentlyModified, metrics: metrics(notes))), ["Apple", "(untitled)", "banana"])
        XCTAssertEqual(titles(NotesSorting.sorted(notes, by: .newestCreated, metrics: metrics(notes))), ["(untitled)", "Apple", "banana"])
        XCTAssertEqual(titles(NotesSorting.sorted(notes, by: .oldestCreated, metrics: metrics(notes))), ["banana", "Apple", "(untitled)"])
    }

    func testLengthSorts() {
        let notes = sampleNotes()
        XCTAssertEqual(titles(NotesSorting.sorted(notes, by: .longest, metrics: metrics(notes))), ["Apple", "(untitled)", "banana"])
        XCTAssertEqual(titles(NotesSorting.sorted(notes, by: .shortest, metrics: metrics(notes))), ["banana", "(untitled)", "Apple"])
    }

    func testWordsLeftSorts() {
        let notes = sampleNotes()
        XCTAssertEqual(titles(NotesSorting.sorted(notes, by: .mostWordsLeft, metrics: metrics(notes))), ["banana", "(untitled)", "Apple"])
        XCTAssertEqual(titles(NotesSorting.sorted(notes, by: .fewestWordsLeft, metrics: metrics(notes))), ["Apple", "(untitled)", "banana"])
    }

    // Higher weight = harder. The note with no saved words (nil difficulty) has no difficulty to
    // compare, so it goes last in BOTH directions rather than winning the easy end.
    func testDifficultySortsPlaceUnscoredNotesLast() {
        let notes = sampleNotes()
        XCTAssertEqual(titles(NotesSorting.sorted(notes, by: .hardest, metrics: metrics(notes))), ["Apple", "banana", "(untitled)"])
        XCTAssertEqual(titles(NotesSorting.sorted(notes, by: .easiest, metrics: metrics(notes))), ["banana", "Apple", "(untitled)"])
    }

    // Equal keys keep their stored positions instead of reshuffling.
    func testTiesFallBackToStoredOrder() {
        let a = Note(title: "a", content: "xx", createdAt: date(0), modifiedAt: date(0))
        let b = Note(title: "b", content: "yy", createdAt: date(0), modifiedAt: date(0))
        let c = Note(title: "c", content: "zz", createdAt: date(0), modifiedAt: date(0))
        let sorted = NotesSorting.sorted([a, b, c], by: .recentlyModified) { _ in NoteSortMetrics(length: 2) }
        XCTAssertEqual(sorted.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(NotesSorting.sorted([a, b, c], by: .longest) { _ in NoteSortMetrics(length: 2) }.map(\.id), [a.id, b.id, c.id])
    }

    // Only the metric-backed orders need NoteSortMetrics; title/date orders read the note itself,
    // which is what lets NotesView skip the saved-word scan for them entirely.
    func testUsesMetricsCoversOnlyMetricBackedOrders() {
        let metricBacked: Set<NotesSortOrder> = [.longest, .shortest, .hardest, .easiest, .mostWordsLeft, .fewestWordsLeft]
        for order in NotesSortOrder.allCases {
            XCTAssertEqual(order.usesMetrics, metricBacked.contains(order), "usesMetrics wrong for \(order.rawValue)")
        }
    }

    // Every option is reachable from the menu, and nothing is listed twice.
    func testMenuGroupsCoverEveryOptionExactlyOnce() {
        let listed = NotesSortOrder.menuGroups.flatMap { $0 }
        XCTAssertEqual(Set(listed), Set(NotesSortOrder.allCases))
        XCTAssertEqual(listed.count, NotesSortOrder.allCases.count)
    }

    // N5 is the easiest (weight 1) and an unleveled word the hardest (weight 6).
    func testDifficultyWeights() {
        XCTAssertEqual(NotesSorting.difficultyWeight(forJLPTLevel: 5), 1)
        XCTAssertEqual(NotesSorting.difficultyWeight(forJLPTLevel: 1), 5)
        XCTAssertEqual(NotesSorting.difficultyWeight(forJLPTLevel: nil), 6)
        XCTAssertEqual(NotesSorting.difficulty(forJLPTLevels: [5, 1]), 3)
        XCTAssertNil(NotesSorting.difficulty(forJLPTLevels: []))
    }
}

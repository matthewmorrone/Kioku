import XCTest
@testable import Kioku

// Covers placing breakdown lines on the note and cutting a line's readings out of the Read
// tab's analysis — the shared join the breakdown and the lyrics popup both rely on.
@MainActor
final class SongBreakdownLineLocatorTests: XCTestCase {
    // Builds a bare breakdown line; only index and original matter to the locator.
    private func line(_ index: Int, _ original: String) -> SongLine {
        SongLine(index: index, original: original, romaji: nil, words: [], gist: nil, grammarNote: nil, reference: nil)
    }

    // A repeated chorus line lands on its own occurrence, not the first one.
    func testRepeatedLineResolvesToItsOwnOccurrence() {
        let note = "サヨナラ\n夢を見た\nサヨナラ"
        let ranges = SongBreakdownLineLocator.noteRanges(for: [line(1, "サヨナラ"), line(2, "夢を見た"), line(3, "サヨナラ")], in: note)
        XCTAssertEqual(ranges[1], NSRange(location: 0, length: 4))
        XCTAssertEqual(ranges[2], NSRange(location: 5, length: 4))
        XCTAssertEqual(ranges[3], NSRange(location: 10, length: 4))
    }

    // A line the model shortened still lands inside its note line; one it rewrote is omitted
    // without stopping the lines after it.
    func testShortenedLineLandsAndRewrittenLineIsOmitted() {
        let note = "かなしみがいま (セーラースマイル)\n書き換えた\n星を持つ"
        let ranges = SongBreakdownLineLocator.noteRanges(for: [line(1, "かなしみがいま"), line(2, "かきかえた"), line(3, "星を持つ")], in: note)
        XCTAssertEqual(ranges[1], NSRange(location: 0, length: 7))
        XCTAssertNil(ranges[2])
        XCTAssertNotNil(ranges[3])
    }

    // Slicing keeps the page's own segments and readings for the line, rebased to the line.
    func testSliceRebasesSegmentsAndReadingsToTheLine() {
        let text = "空\n夢を見た"
        func idx(_ o: Int) -> String.Index { String.Index(utf16Offset: o, in: text) }
        let snapshot = NoteReadingSnapshot(
            text: text,
            segmentRanges: [idx(0)..<idx(1), idx(2)..<idx(3), idx(3)..<idx(4), idx(4)..<idx(6)],
            furiganaBySegmentLocation: [0: "そら", 2: "ゆめ", 4: "み"],
            furiganaLengthBySegmentLocation: [0: 1, 2: 1, 4: 1]
        )
        let cache = snapshot.slice(NSRange(location: 2, length: 4))
        XCTAssertEqual(cache?.sourceText, "夢を見た")
        XCTAssertEqual(cache?.furiganaBySegmentLocation, [0: "ゆめ", 2: "み"])
        XCTAssertEqual(cache?.segmentationRanges.map { NSRange($0, in: "夢を見た") }, [
            NSRange(location: 0, length: 1), NSRange(location: 1, length: 1), NSRange(location: 2, length: 2),
        ])
    }
}

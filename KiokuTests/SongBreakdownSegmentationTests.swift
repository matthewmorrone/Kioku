import XCTest
@testable import Kioku

// Covers rendering the Read tab's segmentation as the breakdown request's Segmentation section.
@MainActor
final class SongBreakdownSegmentationTests: XCTestCase {
    // Lines are numbered skipping blanks, words joined by |, readings bracketed after their run.
    func testRendersNumberedLinesWithInlineReadings() {
        let text = "空\n\n夢を見た"
        func idx(_ o: Int) -> String.Index { String.Index(utf16Offset: o, in: text) }
        let snapshot = NoteReadingSnapshot(
            text: text,
            segmentRanges: [idx(0)..<idx(1), idx(1)..<idx(3), idx(3)..<idx(4), idx(4)..<idx(5), idx(5)..<idx(7)],
            furiganaBySegmentLocation: [0: "そら", 3: "ゆめ", 5: "み"],
            furiganaLengthBySegmentLocation: [0: 1, 3: 1, 5: 1]
        )
        XCTAssertEqual(SongBreakdownSegmentation.section(from: snapshot), "Line 1: 空[そら]\nLine 2: 夢[ゆめ] | を | 見[み]た")
    }

    // No segmentation yet means no section, so the model segments on its own.
    func testEmptySnapshotRendersNothing() {
        let snapshot = NoteReadingSnapshot(text: "空", segmentRanges: [], furiganaBySegmentLocation: [:], furiganaLengthBySegmentLocation: [:])
        XCTAssertEqual(SongBreakdownSegmentation.section(from: snapshot), "")
    }
}

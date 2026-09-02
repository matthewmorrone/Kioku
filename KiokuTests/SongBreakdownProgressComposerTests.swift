import Foundation
import XCTest
@testable import Kioku

// Verifies the row composition SongStepperView scrolls through while a breakdown streams:
// placeholders before anything arrives, streamed lines replacing them from the top with the
// newest highlighted, resync on text match when the model's numbering drifts, and no
// placeholder tail once generation has finished.
@MainActor
final class SongBreakdownProgressComposerTests: XCTestCase {

    private let content = """
    君の名前を呼んだ

    夜の風が吹く
    I said 愛してる to her
    """

    private func streamed(_ index: Int, _ original: String) -> SongLine {
        SongLine(index: index, original: original, romaji: nil, words: [], gist: "g", grammarNote: nil, reference: nil)
    }

    // Blank lines are dropped and the rest numbered contiguously from 1.
    func testPendingLinesSkipBlankLinesAndNumberContiguously() {
        let lines = SongBreakdownProgressComposer.pendingLines(fromNoteContent: content)
        XCTAssertEqual(lines.map(\.index), [1, 2, 3])
        XCTAssertEqual(lines.map(\.original), ["君の名前を呼んだ", "夜の風が吹く", "I said 愛してる to her"])
    }

    // Nothing streamed yet: every note line is a pending placeholder, running or not.
    func testNoStreamedLinesYieldsAllPlaceholders() {
        let items = SongBreakdownProgressComposer.items(noteContent: content, streamedLines: [], isRunning: true)
        XCTAssertEqual(items.map(\.phase), [.pending, .pending, .pending])
        XCTAssertEqual(items.map(\.id), ["pending-0", "pending-1", "pending-2"])
    }

    // While running, the last streamed line is the streaming one and unreached lines follow
    // as placeholders numbered after it.
    func testStreamingMarksLastLineAndAppendsRemainingPlaceholders() {
        let items = SongBreakdownProgressComposer.items(
            noteContent: content,
            streamedLines: [streamed(1, "君の名前を呼んだ"), streamed(2, "夜の風が吹く")],
            isRunning: true
        )
        XCTAssertEqual(items.map(\.phase), [.ready, .streaming, .pending])
        XCTAssertEqual(items[2].line.original, "I said 愛してる to her")
        XCTAssertEqual(items[2].line.index, 3)
    }

    // When the model skips a line, the next streamed line resyncs to its matching placeholder
    // so the skipped placeholder is consumed rather than dragging the tail out of step.
    func testStreamedLineResyncsToMatchingPlaceholderWithinWindow() {
        let items = SongBreakdownProgressComposer.items(
            noteContent: content,
            streamedLines: [streamed(1, "君の名前を呼んだ"), streamed(2, "I said 愛してる to her")],
            isRunning: true
        )
        XCTAssertEqual(items.map(\.phase), [.ready, .streaming])
    }

    // A finished breakdown is shown as parsed — no placeholder tail, nothing highlighted.
    func testFinishedBreakdownHasNoPlaceholdersOrHighlight() {
        let items = SongBreakdownProgressComposer.items(
            noteContent: content,
            streamedLines: [streamed(1, "君の名前を呼んだ")],
            isRunning: false
        )
        XCTAssertEqual(items.map(\.phase), [.ready])
    }

    // Row ids stay unique even when the model repeats a line number.
    func testDuplicateLineIndicesGetDistinctIDs() {
        let items = SongBreakdownProgressComposer.items(
            noteContent: content,
            streamedLines: [streamed(1, "君の名前を呼んだ"), streamed(1, "夜の風が吹く")],
            isRunning: false
        )
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }
}

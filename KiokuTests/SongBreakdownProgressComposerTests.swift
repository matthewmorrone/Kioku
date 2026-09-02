import Foundation
import XCTest
@testable import Kioku

// Verifies the row composition SongStepperView scrolls through while a breakdown streams:
// bare note lines before anything arrives, streamed lines replacing them from the top with
// the newest highlighted, resync on text match when the model's numbering drifts, and no
// note-line tail once generation has finished.
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
    func testNoteLinesSkipBlankLinesAndNumberContiguously() {
        let lines = SongBreakdownProgressComposer.noteLines(fromNoteContent: content)
        XCTAssertEqual(lines.map(\.index), [1, 2, 3])
        XCTAssertEqual(lines.map(\.original), ["君の名前を呼んだ", "夜の風が吹く", "I said 愛してる to her"])
    }

    // Nothing streamed yet: every note line is a bare card, running or not.
    func testNoStreamedLinesYieldsBareNoteLines() {
        let items = SongBreakdownProgressComposer.items(noteContent: content, streamedLines: [], isRunning: true)
        XCTAssertEqual(items.map(\.phase), [.noteText, .noteText, .noteText])
        XCTAssertEqual(items.map(\.id), ["note-0", "note-1", "note-2"])
    }

    // While running, the last streamed line is the streaming one and unreached note lines
    // follow, numbered after it.
    func testStreamingMarksLastLineAndAppendsRemainingNoteLines() {
        let items = SongBreakdownProgressComposer.items(
            noteContent: content,
            streamedLines: [streamed(1, "君の名前を呼んだ"), streamed(2, "夜の風が吹く")],
            isRunning: true
        )
        XCTAssertEqual(items.map(\.phase), [.ready, .streaming, .noteText])
        XCTAssertEqual(items[2].line.original, "I said 愛してる to her")
        XCTAssertEqual(items[2].line.index, 3)
    }

    // When the model skips a line, the next streamed line resyncs to its matching note line
    // so the skipped one is consumed rather than dragging the tail out of step.
    func testStreamedLineResyncsToMatchingNoteLineWithinWindow() {
        let items = SongBreakdownProgressComposer.items(
            noteContent: content,
            streamedLines: [streamed(1, "君の名前を呼んだ"), streamed(2, "I said 愛してる to her")],
            isRunning: true
        )
        XCTAssertEqual(items.map(\.phase), [.ready, .streaming])
    }

    // A finished breakdown is shown as parsed — no note-line tail, nothing highlighted.
    func testFinishedBreakdownHasNoNoteLineTailOrHighlight() {
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

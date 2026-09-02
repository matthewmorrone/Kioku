import Foundation
import XCTest
@testable import Kioku

// Verifies the row composition SongStepperView scrolls through: the last streamed line is
// highlighted only while streaming, a finished breakdown has no highlight, and ids stay
// unique when the model repeats a line number.
@MainActor
final class SongBreakdownProgressComposerTests: XCTestCase {

    private func line(_ index: Int, _ original: String) -> SongLine {
        SongLine(index: index, original: original, romaji: nil, words: [], gist: "g", grammarNote: nil, reference: nil)
    }

    // While streaming, only the last line is marked as being written.
    func testStreamingMarksOnlyLastLine() {
        let items = SongBreakdownProgressComposer.items(
            lines: [line(1, "君の名前を呼んだ"), line(2, "夜の風が吹く")],
            isStreaming: true
        )
        XCTAssertEqual(items.map(\.phase), [.ready, .streaming])
    }

    // A finished breakdown is shown as parsed — nothing highlighted.
    func testFinishedBreakdownHasNoHighlight() {
        let items = SongBreakdownProgressComposer.items(lines: [line(1, "君の名前を呼んだ")], isStreaming: false)
        XCTAssertEqual(items.map(\.phase), [.ready])
    }

    // Row ids stay unique even when the model repeats a line number.
    func testDuplicateLineIndicesGetDistinctIDs() {
        let items = SongBreakdownProgressComposer.items(
            lines: [line(1, "君の名前を呼んだ"), line(1, "夜の風が吹く")],
            isStreaming: false
        )
        XCTAssertEqual(Set(items.map(\.id)).count, 2)
    }

    // No lines yields no rows, streaming or not.
    func testEmptyLinesYieldNoRows() {
        XCTAssertTrue(SongBreakdownProgressComposer.items(lines: [], isStreaming: true).isEmpty)
    }

    // The line listen-along is speaking is marked playing; streaming wins if both apply.
    func testPlayingLineIsMarked() {
        let items = SongBreakdownProgressComposer.items(
            lines: [line(1, "君の名前を呼んだ"), line(2, "夜の風が吹く")],
            isStreaming: false,
            playingLineIndex: 2
        )
        XCTAssertEqual(items.map(\.phase), [.ready, .playing])
    }
}

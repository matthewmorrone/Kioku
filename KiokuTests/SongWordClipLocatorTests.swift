import XCTest
@testable import Kioku

// Characterizes SongWordClipLocator: a word's sung range is its covering checkpoint's onset to
// the next checkpoint's onset (or the line end), repeated words map in order, and anything the
// checkpoints can't bracket yields no snippet.
@MainActor
final class SongWordClipLocatorTests: XCTestCase {
    // "君の名前を君に" with one checkpoint per word/particle.
    private let cue = SubtitleCue(index: 1, startMs: 0, endMs: 5000, text: "君の名前を君に", checkpoints: [
        CueCharTiming(timeMs: 100, charOffsetInCue: 0, charLength: 1),
        CueCharTiming(timeMs: 500, charOffsetInCue: 1, charLength: 1),
        CueCharTiming(timeMs: 700, charOffsetInCue: 2, charLength: 2),
        CueCharTiming(timeMs: 1300, charOffsetInCue: 4, charLength: 1),
        CueCharTiming(timeMs: 1500, charOffsetInCue: 5, charLength: 1),
        CueCharTiming(timeMs: 2000, charOffsetInCue: 6, charLength: 1),
    ])

    // A mid-line word runs from its own onset to the next sound's onset.
    func testMidLineWordRunsToNextOnset() throws {
        let located = try XCTUnwrap(SongWordClipLocator.locate("名前", in: cue, lineEndMs: 2400, searchFrom: 0))
        XCTAssertEqual(located.startMs, 700)
        XCTAssertEqual(located.endMs, 1300)
        XCTAssertEqual(located.nextSearchFrom, 4)
    }

    // A word sung twice maps to its second occurrence when searching past the first.
    func testRepeatedWordMapsInOrder() throws {
        let first = try XCTUnwrap(SongWordClipLocator.locate("君", in: cue, lineEndMs: 2400, searchFrom: 0))
        let second = try XCTUnwrap(SongWordClipLocator.locate("君", in: cue, lineEndMs: 2400, searchFrom: first.nextSearchFrom))
        XCTAssertEqual(first.startMs, 100)
        XCTAssertEqual(second.startMs, 1500)
    }

    // The line's last sound runs to the line end.
    func testLastWordRunsToLineEnd() throws {
        let located = try XCTUnwrap(SongWordClipLocator.locate("に", in: cue, lineEndMs: 2400, searchFrom: 0))
        XCTAssertEqual(located.startMs, 2000)
        XCTAssertEqual(located.endMs, 2400)
    }

    // A long gap inside the line is cut at the maximum snippet length.
    func testSnippetIsCappedAtMaximumDuration() throws {
        let located = try XCTUnwrap(SongWordClipLocator.locate("に", in: cue, lineEndMs: 9000, searchFrom: 0))
        XCTAssertEqual(located.endMs - located.startMs, SongWordClipLocator.maximumDurationMs)
    }

    // No snippet for a surface that isn't sung in this line, or a cue that was never aligned.
    func testNoSnippetWithoutTextMatchOrCheckpoints() {
        XCTAssertNil(SongWordClipLocator.locate("呼ぶ", in: cue, lineEndMs: 2400, searchFrom: 0))
        var unaligned = cue
        unaligned.checkpoints = []
        XCTAssertNil(SongWordClipLocator.locate("名前", in: unaligned, lineEndMs: 2400, searchFrom: 0))
    }
}

import XCTest
@testable import Kioku

// Pins how cue lines become furigana runs for the lyrics Live Activity: runs tile the line with
// no gaps, readings attach to whole kanji runs, and the line stops at the first newline.
@MainActor
final class LyricsActivityRubyBuilderTests: XCTestCase {
    // Kanji runs get their reading; the kana between them stay plain.
    func testSplitsLineIntoPlainAndRubyRuns() {
        let note = "君の名前\n次の行"
        let cue = SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "君の名前")
        let runs = LyricsActivityRubyBuilder.runs(
            cues: [cue],
            highlightRanges: [NSRange(location: 0, length: 4)],
            noteText: note,
            furiganaBySegmentLocation: [0: "きみ", 2: "なまえ", 5: "つぎ"],
            furiganaLengthBySegmentLocation: [0: 1, 2: 2, 5: 1]
        )
        XCTAssertEqual(runs, [[
            LyricsActivityRubyRun(text: "君", ruby: "きみ"),
            LyricsActivityRubyRun(text: "の", ruby: nil),
            LyricsActivityRubyRun(text: "名前", ruby: "なまえ"),
        ]])
    }

    // A cue range that bleeds past a newline is clipped, and furigana beyond it is dropped.
    func testClipsAtFirstNewline() {
        let note = "空\n海"
        let runs = LyricsActivityRubyBuilder.runs(
            in: NSRange(location: 0, length: 3),
            of: note as NSString,
            furiganaBySegmentLocation: [0: "そら", 2: "うみ"],
            furiganaLengthBySegmentLocation: [0: 1, 2: 1]
        )
        XCTAssertEqual(runs, [LyricsActivityRubyRun(text: "空", ruby: "そら")])
    }

    // A cue whose text isn't in the note falls back to one plain run of its first line.
    func testUnmatchedCueFallsBackToPlainText() {
        let cue = SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: " ラララ \nsecond")
        let runs = LyricsActivityRubyBuilder.runs(
            cues: [cue],
            highlightRanges: [nil],
            noteText: "別の歌",
            furiganaBySegmentLocation: [:],
            furiganaLengthBySegmentLocation: [:]
        )
        XCTAssertEqual(runs, [[LyricsActivityRubyRun(text: "ラララ", ruby: nil)]])
    }
}

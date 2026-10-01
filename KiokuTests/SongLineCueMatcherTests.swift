import XCTest
@testable import Kioku

// Covers how breakdown lines are paired with the note's alignment cues for listen-along clips.
@MainActor
final class SongLineCueMatcherTests: XCTestCase {
    // Builds a bare breakdown line; only index and original matter to the matcher.
    private func line(_ index: Int, _ original: String) -> SongLine {
        SongLine(index: index, original: original, romaji: nil, words: [], gist: nil, grammarNote: nil, reference: nil)
    }

    // Builds a cue with consecutive one-second timing.
    private func cue(_ index: Int, _ text: String) -> SubtitleCue {
        SubtitleCue(index: index, startMs: index * 1000, endMs: index * 1000 + 1000, text: text)
    }

    // A line the LLM shortened (parenthesised backing vocal dropped on the user's note) still
    // finds its cue, and the lines after it keep matching in order.
    func testShortenedLineMatchesTheCueThatContainsIt() {
        let cues = [cue(1, "かなしみがいま (セーラースマイル)"), cue(2, "だれだってかがやく星を持つ")]
        let matched = SongLineCueMatcher.matchedCues(lines: [line(1, "かなしみがいま"), line(2, "だれだってかがやく星を持つ")], cues: cues)
        XCTAssertEqual(matched[1]?.index, 1)
        XCTAssertEqual(matched[2]?.index, 2)
    }

    // The clip for a shortened line stops where the dropped text starts being sung.
    func testShortenedLineClipEndsBeforeTheDroppedText() {
        let cue = SubtitleCue(index: 1, startMs: 1000, endMs: 5000, text: "かなしみ (セーラー)", checkpoints: [
            CueCharTiming(timeMs: 1000, charOffsetInCue: 0, charLength: 1),
            CueCharTiming(timeMs: 2000, charOffsetInCue: 3, charLength: 1),
            CueCharTiming(timeMs: 3200, charOffsetInCue: 6, charLength: 1),
        ])
        let ranges = SongLineCueMatcher.computeRanges(lines: [line(1, "かなしみ")], cues: [cue])
        XCTAssertEqual(ranges[1]?.startMs, 1000)
        XCTAssertEqual(ranges[1]?.endMs, 3200)
    }

    // An equal cue later in the song beats an earlier cue that merely contains the line.
    func testEqualCueAheadWinsOverContainingCue() {
        let cues = [cue(1, "あなたについてく道"), cue(2, "あなたについてく")]
        let matched = SongLineCueMatcher.matchedCues(lines: [line(1, "あなたについてく")], cues: cues)
        XCTAssertEqual(matched[1]?.index, 2)
    }
}

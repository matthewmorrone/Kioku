import XCTest
@testable import Kioku

// Pins which checkpoints become squiggles: only scored ones under the threshold, placed at the cue's
// note range, merged when touching.
final class AlignmentStruggleSpansTests: XCTestCase {
    private func cue(_ checkpoints: [CueCharTiming]) -> SubtitleCue {
        SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "abcdef", checkpoints: checkpoints)
    }

    func testFlagsOnlyLowConfidenceCheckpointsAtNoteOffsets() {
        let cues = [cue([
            CueCharTiming(timeMs: 0, charOffsetInCue: 0, charLength: 2, confidence: 0.9),
            CueCharTiming(timeMs: 100, charOffsetInCue: 2, charLength: 2, confidence: 0.1),
            CueCharTiming(timeMs: 200, charOffsetInCue: 4, charLength: 2, confidence: nil),
        ])]
        let ranges = AlignmentStruggleSpans.ranges(cues: cues, highlightRanges: [NSRange(location: 10, length: 6)])
        XCTAssertEqual(ranges, [NSRange(location: 12, length: 2)])
    }

    func testMergesTouchingRangesAndSkipsUnplacedCues() {
        let cues = [cue([
            CueCharTiming(timeMs: 0, charOffsetInCue: 0, charLength: 2, confidence: 0.1),
            CueCharTiming(timeMs: 100, charOffsetInCue: 2, charLength: 2, confidence: 0.2),
        ]), cue([CueCharTiming(timeMs: 0, charOffsetInCue: 0, charLength: 1, confidence: 0.0)])]
        let ranges = AlignmentStruggleSpans.ranges(cues: cues, highlightRanges: [NSRange(location: 0, length: 6), nil])
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 4)])
    }
}

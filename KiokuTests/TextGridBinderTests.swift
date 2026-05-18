import XCTest
@testable import Kioku

// Verifies the TextGrid → CueCharTimings binder. Forced-aligner output is noisy; the binder
// must drop misaligned intervals without crashing or rewinding the per-cue cursor.
final class TextGridBinderTests: XCTestCase {

    // Builds a single-tier TextGridFile inline so tests don't depend on the parser.
    private func makeFile(_ intervals: [(Double, Double, String)], tierName: String = "words") -> TextGridFile {
        TextGridFile(
            durationMs: Int(((intervals.last?.1 ?? 0.0) * 1000).rounded()),
            tiers: [TextGridTier(
                name: tierName,
                intervals: intervals.map { TextGridInterval(
                    startMs: Int(($0.0 * 1000).rounded()),
                    endMs: Int(($0.1 * 1000).rounded()),
                    text: $0.2
                ) }
            )]
        )
    }

    func testCleanAlignmentEmitsCheckpoints() {
        let cues = [SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "ごめん")]
        let grid = makeFile([
            (0.0, 0.3, "ご"),
            (0.3, 0.6, "め"),
            (0.6, 0.9, "ん"),
        ])
        let result = TextGridBinder.bindCheckpoints(textGrid: grid, cues: cues)
        XCTAssertEqual(result[1]?.count, 3)
        XCTAssertEqual(result[1]?[0].charOffsetInCue, 0)
        XCTAssertEqual(result[1]?[0].charLength, 1)
        XCTAssertEqual(result[1]?[1].charOffsetInCue, 1)
        XCTAssertEqual(result[1]?[2].timeMs, 600)
    }

    func testSilenceIntervalsAreSkipped() {
        let cues = [SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "ごめん")]
        let grid = makeFile([
            (0.0, 0.2, ""),
            (0.2, 0.4, "ご"),
            (0.4, 0.5, ""),
            (0.5, 0.7, "め"),
        ])
        let result = TextGridBinder.bindCheckpoints(textGrid: grid, cues: cues)
        XCTAssertEqual(result[1]?.count, 2)
        XCTAssertEqual(result[1]?[1].charOffsetInCue, 1)
    }

    func testNoisyIntervalsAreDropped() {
        let cues = [SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "ごめん")]
        let grid = makeFile([
            (0.0, 0.2, "ご"),
            (0.2, 0.3, "ショ"),
            (0.3, 0.5, "め"),
        ])
        let result = TextGridBinder.bindCheckpoints(textGrid: grid, cues: cues)
        XCTAssertEqual(result[1]?.count, 2)
        XCTAssertEqual(result[1]?[1].charOffsetInCue, 1)
        XCTAssertEqual(result[1]?[1].timeMs, 300)
    }

    func testTwoCharacterLabelMatchesCluster() {
        let cues = [SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "だって")]
        let grid = makeFile([
            (0.0, 0.2, "だ"),
            (0.2, 0.6, "って"),
        ])
        let result = TextGridBinder.bindCheckpoints(textGrid: grid, cues: cues)
        XCTAssertEqual(result[1]?.count, 2)
        XCTAssertEqual(result[1]?[1].charOffsetInCue, 1)
        XCTAssertEqual(result[1]?[1].charLength, 2)
    }

    func testOutOfRangeIntervalsAreDropped() {
        let cues = [SubtitleCue(index: 1, startMs: 1000, endMs: 2000, text: "ごめん")]
        let grid = makeFile([
            (0.0, 0.2, "x"),
            (1.0, 1.2, "ご"),
            (5.0, 5.2, "y"),
        ])
        let result = TextGridBinder.bindCheckpoints(textGrid: grid, cues: cues)
        XCTAssertEqual(result[1]?.count, 1)
        XCTAssertNil(result[2])
    }

    func testPerCueCursorsAreIndependent() {
        let cues = [
            SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "ごめん"),
            SubtitleCue(index: 2, startMs: 1000, endMs: 2000, text: "あり"),
        ]
        let grid = makeFile([
            (0.0, 0.3, "ご"),
            (1.0, 1.2, "あ"),
            (1.2, 1.5, "り"),
        ])
        let result = TextGridBinder.bindCheckpoints(textGrid: grid, cues: cues)
        XCTAssertEqual(result[1]?.count, 1)
        XCTAssertEqual(result[2]?.count, 2)
        XCTAssertEqual(result[2]?[0].charOffsetInCue, 0)
    }

    func testTierSelectionPicksHighestResolution() {
        let cues = [SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "ごめん")]
        let coarse = TextGridTier(name: "segments", intervals: [
            TextGridInterval(startMs: 0, endMs: 1000, text: "ごめん"),
        ])
        let fine = TextGridTier(name: "words", intervals: [
            TextGridInterval(startMs: 0,   endMs: 300, text: "ご"),
            TextGridInterval(startMs: 300, endMs: 600, text: "め"),
            TextGridInterval(startMs: 600, endMs: 900, text: "ん"),
        ])
        let grid = TextGridFile(durationMs: 1000, tiers: [coarse, fine])
        let result = TextGridBinder.bindCheckpoints(textGrid: grid, cues: cues)
        XCTAssertEqual(result[1]?.count, 3)
    }

    func testSingleLineTierIsUsedAsFallback() {
        let cues = [SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "ごめん")]
        let grid = makeFile([(0.0, 1.0, "ごめん")], tierName: "segments")
        let result = TextGridBinder.bindCheckpoints(textGrid: grid, cues: cues)
        XCTAssertEqual(result[1]?.count, 1)
        XCTAssertEqual(result[1]?[0].charLength, 3)
    }

    func testCueWithNoMatchesIsOmitted() {
        let cues = [SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "ごめん")]
        let grid = makeFile([
            (0.1, 0.2, "x"),
            (0.3, 0.4, "y"),
        ])
        let result = TextGridBinder.bindCheckpoints(textGrid: grid, cues: cues)
        XCTAssertNil(result[1])
    }
}

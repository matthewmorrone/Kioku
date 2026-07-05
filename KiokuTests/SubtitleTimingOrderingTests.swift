import XCTest
@testable import Kioku

// Pins the time-sorted invariant that the karaoke display (LyricsView renders + seeks cues by array
// index) and the ♪-insertion helpers all assume but nothing used to enforce on the fresh-align path.
// The reconcile path already sorts (SubtitleReconciliation.mergeReconciledCues); these cases lock the
// same guarantee into the marker/normalize helpers so a non-monotonic aligner line (or an onset
// clamp that pushes a line past its neighbor) can't strand a lyric on the wrong side of an interlude.
@MainActor
final class SubtitleTimingOrderingTests: XCTestCase {
    private func cue(_ index: Int, _ start: Int, _ end: Int, _ text: String) -> SubtitleCue {
        SubtitleCue(index: index, startMs: start, endMs: end, text: text)
    }

    private func isMonotonic(_ cues: [SubtitleCue]) -> Bool {
        zip(cues, cues.dropFirst()).allSatisfy { $0.startMs <= $1.startMs }
    }

    // A, B are early; C resumes after a long instrumental gap — but the aligner emitted them out of
    // time order (C before B in the array). The ♪ must land between B and C, not strand B below C.
    private var outOfOrderSpeech: [SubtitleCue] {
        [cue(1, 0, 1000, "A"), cue(2, 30_000, 31_000, "C"), cue(3, 2000, 3000, "B")]
    }

    func testHeuristicMarkersSortAndPlaceInterludeCorrectly() {
        let out = SubtitleEditorTimingTools.insertMusicMarkers(
            cues: outOfOrderSpeech, durationMs: 32_000, gapThresholdMs: 5000
        )
        XCTAssertTrue(isMonotonic(out), "marker insertion must yield time-sorted cues")
        let texts = out.map(\.text)
        XCTAssertLessThan(texts.firstIndex(of: "B")!, texts.firstIndex(of: "♪")!)
        XCTAssertLessThan(texts.firstIndex(of: "♪")!, texts.firstIndex(of: "C")!)
    }

    func testVADMarkersSortSpeechBeforeInterleaving() {
        // Vocal on [0,3s] and [30,31s]; the [3s,30s] silence is the interlude.
        let vocalSegments = [(start: 0.0, end: 3.0), (start: 30.0, end: 31.0)]
        let out = SubtitleEditorTimingTools.insertMusicMarkers(
            cues: outOfOrderSpeech, durationMs: 32_000, vocalSegments: vocalSegments, minGapMs: 4000
        )
        XCTAssertTrue(isMonotonic(out), "VAD marker insertion must yield time-sorted cues")
        let texts = out.map(\.text)
        XCTAssertLessThan(texts.firstIndex(of: "B")!, texts.firstIndex(of: "♪")!)
        XCTAssertLessThan(texts.firstIndex(of: "♪")!, texts.firstIndex(of: "C")!)
    }

    func testNormalizeTimingSortsOutOfOrderCues() {
        let out = SubtitleEditorTimingTools.normalizeTiming(cues: outOfOrderSpeech, gapThresholdMs: 5000)
        XCTAssertTrue(isMonotonic(out), "normalizeTiming must yield time-sorted cues")
    }

    func testAlreadySortedCuesAreUnperturbed() {
        let sorted = [cue(1, 0, 1000, "A"), cue(2, 2000, 3000, "B"), cue(3, 30_000, 31_000, "C")]
        let out = SubtitleEditorTimingTools.insertMusicMarkers(cues: sorted, durationMs: 32_000, gapThresholdMs: 5000)
        XCTAssertTrue(isMonotonic(out))
        // Speech order preserved, one ♪ inserted for the single large gap.
        XCTAssertEqual(out.filter { SubtitleParser.isNonSpeechCue($0.text) == false }.map(\.text), ["A", "B", "C"])
        XCTAssertEqual(out.filter { SubtitleParser.isNonSpeechCue($0.text) }.count, 1)
    }
}

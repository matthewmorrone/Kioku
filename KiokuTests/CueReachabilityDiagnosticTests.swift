import XCTest
@testable import Kioku

// Pins CueReachabilityDiagnostic to AudioPlaybackController.resolveActiveCue's "current" rule:
// a cue is reachable iff some instant in its half-open [startMs, endMs) is not already claimed by
// an earlier-indexed cue. These cases cover the two defect shapes the diagnostic exists to catch —
// zero/inverted intervals and fully-shadowed lines — plus the negatives that must stay clean.
final class CueReachabilityDiagnosticTests: XCTestCase {
    private func cue(_ index: Int, _ start: Int, _ end: Int, _ text: String = "x") -> SubtitleCue {
        SubtitleCue(index: index, startMs: start, endMs: end, text: text)
    }

    func testSequentialCuesAllReachable() {
        let cues = [cue(1, 0, 1000), cue(2, 1000, 2000), cue(3, 2000, 3000)]
        XCTAssertTrue(CueReachabilityDiagnostic.unreachableCues(cues).isEmpty)
    }

    func testZeroDurationCueFlaggedEmpty() {
        let cues = [cue(1, 0, 1000), cue(2, 1500, 1500), cue(3, 2000, 3000)]
        let findings = CueReachabilityDiagnostic.unreachableCues(cues)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.arrayIndex, 1)
        XCTAssertEqual(findings.first?.reason, .emptyInterval)
    }

    func testInvertedIntervalFlaggedEmpty() {
        let cues = [cue(1, 2000, 1000)]
        XCTAssertEqual(CueReachabilityDiagnostic.unreachableCues(cues).first?.reason, .emptyInterval)
    }

    func testFullyShadowedCueFlagged() {
        // Cue 2 sits entirely inside cue 1's interval — firstIndex always returns cue 1 for any
        // instant cue 2 covers, so cue 2 can never be current.
        let cues = [cue(1, 0, 5000), cue(2, 1000, 2000)]
        let findings = CueReachabilityDiagnostic.unreachableCues(cues)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.arrayIndex, 1)
        XCTAssertEqual(findings.first?.reason, .shadowed)
    }

    func testPartiallyOverlappedCueStaysReachable() {
        // Cue 2 pokes past cue 1's end, so [2000,3000) has uncovered instants — reachable.
        let cues = [cue(1, 0, 2000), cue(2, 1000, 3000)]
        XCTAssertTrue(CueReachabilityDiagnostic.unreachableCues(cues).isEmpty)
    }

    func testShadowedByUnionOfTwoEarlierCues() {
        // Neither earlier cue alone covers cue 3, but together they tile [0,4000), so cue 3 is
        // fully shadowed by the union.
        let cues = [cue(1, 0, 2000), cue(2, 2000, 4000), cue(3, 500, 3500)]
        let findings = CueReachabilityDiagnostic.unreachableCues(cues)
        XCTAssertEqual(findings.map(\.arrayIndex), [2])
        XCTAssertEqual(findings.first?.reason, .shadowed)
    }

    func testEmptyInputProducesNoFindings() {
        XCTAssertTrue(CueReachabilityDiagnostic.unreachableCues([]).isEmpty)
    }
}

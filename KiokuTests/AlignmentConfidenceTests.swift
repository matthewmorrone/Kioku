import XCTest
@testable import Kioku

// Pins the whole-song score (mean of scored checkpoints), the warning gate, and the per-song dismissal.
final class AlignmentConfidenceTests: XCTestCase {
    private func cue(_ confidences: [Float?]) -> SubtitleCue {
        let checkpoints = confidences.enumerated().map {
            CueCharTiming(timeMs: $0.offset * 100, charOffsetInCue: $0.offset, charLength: 1, confidence: $0.element)
        }
        return SubtitleCue(index: 1, startMs: 0, endMs: 1000, text: "abc", checkpoints: checkpoints)
    }

    func testScoreIsMeanOfScoredCheckpointsAcrossCues() {
        let score = AlignmentConfidence.score(of: [cue([0.2, nil]), cue([0.4])])
        XCTAssertEqual(score ?? -1, 0.3, accuracy: 0.0001)
    }

    func testUnscoredCuesHaveNoScoreAndNoWarning() {
        XCTAssertNil(AlignmentConfidence.score(of: [cue([nil, nil])]))
        XCTAssertNil(AlignmentConfidence.warningPercent(for: [cue([nil])]))
    }

    func testWarnsOnlyBelowThresholdWithWholePercent() {
        XCTAssertEqual(AlignmentConfidence.warningPercent(for: [cue([0.30, 0.31])]), 31)
        XCTAssertNil(AlignmentConfidence.warningPercent(for: [cue([0.9])]))
    }

    func testDismissalIsPerNote() {
        let defaults = UserDefaults(suiteName: "AlignmentConfidenceTests-\(UUID().uuidString)")!
        let note = UUID()
        XCTAssertFalse(AlignmentConfidence.isDismissed(noteID: note, defaults: defaults))
        AlignmentConfidence.dismiss(noteID: note, defaults: defaults)
        XCTAssertTrue(AlignmentConfidence.isDismissed(noteID: note, defaults: defaults))
        XCTAssertFalse(AlignmentConfidence.isDismissed(noteID: UUID(), defaults: defaults))
    }
}

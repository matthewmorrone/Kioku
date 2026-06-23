import XCTest
@testable import Kioku

// Pins SubtitleEditorTimingTools.clampOnsetsToVocal — the ground-truth safety net that pulls any
// cue whose ONSET landed inside a proven instrumental gap (a stretch with no energy-VAD vocal
// segment) forward to where the vocal actually resumes. A sung line physically cannot begin during
// stem silence, so a VAD gap edge is a hard wall, exactly like an alignment anchor.
//
// Regression source: "Moon Pride" (ムーンプライド). The energy-VAD found the 25 s interlude gap
// [128.2s, 153.2s], but anchor-fill parked the two post-interlude lines at 130.3s / 134.1s — inside
// the silence. Left there they (a) swept "ghostly" over no audio and (b) suppressed the ♪ marker,
// because insertMusicMarkers skips a gap that a cue starts inside. Clamping the onsets out of the
// gap fixes both symptoms at once.
@MainActor
final class SubtitleVocalClampTests: XCTestCase {

    private func cue(_ text: String, _ startMs: Int, _ endMs: Int,
                     _ checkpoints: [CueCharTiming] = []) -> SubtitleCue {
        SubtitleCue(index: 0, startMs: startMs, endMs: endMs, text: text, checkpoints: checkpoints)
    }

    private func cp(_ timeMs: Int, _ offset: Int, _ length: Int) -> CueCharTiming {
        CueCharTiming(timeMs: timeMs, charOffsetInCue: offset, charLength: length)
    }

    // The Moon Pride interlude, miniaturized: vocal regions [0,128.2s] and [153.2s,200s] with a real
    // 25 s gap between them. Two lines drifted to onsets 130.3s / 134.1s — inside the gap.
    private let vocals: [(start: Double, end: Double)] = [(0, 128.2), (153.2, 200)]
    private let durationMs = 218_136

    // The core fix: no speech cue may begin inside the proven-silent gap after clamping.
    func testInGapOnsetsArePushedToVocalResumption() {
        let cues = [
            cue("時空を越えた絆が私に勇気をくれる", 122_260, 127_480),   // last real pre-gap line
            cue("恋しくて切なくて泣きたくなるよ", 130_280, 134_060),       // INSIDE the gap
            cue("逢いたくて寂しくて駆け出しそうなハート", 134_060, 164_516), // INSIDE the gap
            cue("この広い宇宙で何度生まれ変わっても", 164_516, 169_576),   // first legit post-gap line
        ]
        let out = SubtitleEditorTimingTools.clampOnsetsToVocal(
            cues: cues, durationMs: durationMs, vocalSegments: vocals)

        // No onset survives inside (128_200, 153_200).
        for c in out {
            XCTAssertFalse(c.startMs > 128_200 && c.startMs < 153_200,
                           "‘\(c.text)’ still starts at \(c.startMs), inside the interlude")
        }
        // The two drifted lines now sit in the post-gap window, in order, before the next legit line.
        XCTAssertGreaterThanOrEqual(out[1].startMs, 153_200)
        XCTAssertGreaterThan(out[2].startMs, out[1].startMs)
        XCTAssertLessThanOrEqual(out[3].startMs, 164_516)   // untouched legit line keeps its onset
        XCTAssertEqual(out[3].startMs, 164_516)
        // The pre-gap line is in real vocal time → untouched.
        XCTAssertEqual(out[0].startMs, 122_260)
    }

    // End-to-end: after clamping, insertMusicMarkers emits the ♪ that the raw cues suppressed.
    func testClampRestoresSuppressedInterludeMarker() {
        let cues = [
            cue("時空を越えた絆が私に勇気をくれる", 122_260, 127_480),
            cue("恋しくて切なくて泣きたくなるよ", 130_280, 134_060),
            cue("逢いたくて寂しくて駆け出しそうなハート", 134_060, 164_516),
            cue("この広い宇宙で何度生まれ変わっても", 164_516, 169_576),
        ]
        // Raw cues: the interlude ♪ is suppressed (a cue starts inside the gap).
        let rawMarked = SubtitleEditorTimingTools.insertMusicMarkers(
            cues: cues, durationMs: durationMs, vocalSegments: vocals)
        let rawInterludeMarkers = rawMarked.filter {
            SubtitleParser.isNonSpeechCue($0.text) && $0.startMs >= 127_480 && $0.endMs <= 154_000
        }
        XCTAssertTrue(rawInterludeMarkers.isEmpty, "precondition: raw cues suppress the interlude ♪")

        // Clamp first, then insert markers: the interlude ♪ reappears.
        let clamped = SubtitleEditorTimingTools.clampOnsetsToVocal(
            cues: cues, durationMs: durationMs, vocalSegments: vocals)
        let marked = SubtitleEditorTimingTools.insertMusicMarkers(
            cues: clamped, durationMs: durationMs, vocalSegments: vocals)
        let interludeMarkers = marked.filter {
            SubtitleParser.isNonSpeechCue($0.text) && $0.startMs >= 127_480 && $0.endMs <= 154_000
        }
        XCTAssertEqual(interludeMarkers.count, 1, "the interlude ♪ should be restored")
    }

    // Cues already in real vocal time are never moved.
    func testOnsetsInVocalTimeAreUntouched() {
        let cues = [
            cue("一行目", 10_000, 14_000),
            cue("二行目", 60_000, 64_000),
            cue("三行目", 160_000, 164_000),
        ]
        let out = SubtitleEditorTimingTools.clampOnsetsToVocal(
            cues: cues, durationMs: durationMs, vocalSegments: vocals)
        XCTAssertEqual(out.map(\.startMs), cues.map(\.startMs))
    }

    // No VAD info → identity (we have no ground truth to clamp against).
    func testNoVocalSegmentsIsIdentity() {
        let cues = [cue("一行目", 130_000, 134_000)]
        let out = SubtitleEditorTimingTools.clampOnsetsToVocal(
            cues: cues, durationMs: durationMs, vocalSegments: [])
        XCTAssertEqual(out.map(\.startMs), cues.map(\.startMs))
    }

    // Checkpoints ride along: re-anchored by the start delta, and any pushed past the new end drop.
    func testCheckpointsReanchorOnClamp() {
        let cues = [
            cue("恋しくて", 130_000, 134_000, [cp(130_000, 0, 1), cp(132_000, 1, 1)]),
            cue("この広い宇宙で", 160_000, 164_000),
        ]
        let out = SubtitleEditorTimingTools.clampOnsetsToVocal(
            cues: cues, durationMs: durationMs, vocalSegments: vocals)
        let moved = out[0]
        XCTAssertGreaterThanOrEqual(moved.startMs, 153_200)
        // Delta applied, all checkpoints stay within the moved cue's bounds.
        for c in moved.checkpoints {
            XCTAssertGreaterThanOrEqual(c.timeMs, moved.startMs)
            XCTAssertLessThanOrEqual(c.timeMs, moved.endMs)
        }
        // First checkpoint pins to the new onset (delta = newStart - 130_000).
        XCTAssertEqual(moved.checkpoints.first?.timeMs, moved.startMs)
    }
}

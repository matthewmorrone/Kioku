import XCTest
@testable import Kioku

// Pins SubtitleEditorTimingTools.mergeCheckpoints — the function that carries per-word karaoke
// checkpoints across the SRT editor's lossy text round-trip. The editor (and the sync-to-note
// flow) re-parse SRT text into checkpoint-less cues; this merge re-attaches the pre-edit
// checkpoints to every line whose TEXT is unchanged, re-anchored by the line's start-time delta,
// and drops them only where the text actually changed. cues.json is the single source of truth,
// so these are the rules that decide when editing the SRT preserves vs. discards word timing.
@MainActor
final class SubtitleCheckpointMergeTests: XCTestCase {

    // Builds a cue with optional checkpoints — keeps the cases readable.
    private func cue(_ text: String, _ startMs: Int, _ endMs: Int,
                     _ checkpoints: [CueCharTiming] = []) -> SubtitleCue {
        SubtitleCue(index: 0, startMs: startMs, endMs: endMs, text: text, checkpoints: checkpoints)
    }

    // Builds a single checkpoint — shorthand for the cases.
    private func cp(_ timeMs: Int, _ offset: Int, _ length: Int) -> CueCharTiming {
        CueCharTiming(timeMs: timeMs, charOffsetInCue: offset, charLength: length)
    }

    // Identical text + identical timing: checkpoints carry over byte-for-byte (delta 0). This is the
    // open-editor-and-save-with-no-edits regression — the bug that silently wiped word timing.
    func testUnchangedLineCarriesCheckpointsVerbatim() {
        let prev = [cue("猫が鳴く", 1000, 2000, [cp(1000, 0, 1), cp(1400, 1, 1)])]
        let edited = [cue("猫が鳴く", 1000, 2000)]
        let merged = SubtitleEditorTimingTools.mergeCheckpoints(into: edited, from: prev)
        XCTAssertEqual(merged[0].checkpoints, prev[0].checkpoints)
    }

    // Text changed: the old character offsets no longer describe the line, so checkpoints drop.
    func testChangedTextDropsCheckpoints() {
        let prev = [cue("猫が鳴く", 1000, 2000, [cp(1000, 0, 1)])]
        let edited = [cue("犬が鳴く", 1000, 2000)]
        let merged = SubtitleEditorTimingTools.mergeCheckpoints(into: edited, from: prev)
        XCTAssertTrue(merged[0].checkpoints.isEmpty)
    }

    // Pure time shift (Shift tool / manual timecode edit): checkpoints re-anchored by the delta.
    func testTimeShiftReanchorsCheckpoints() {
        let prev = [cue("猫が鳴く", 1000, 2000, [cp(1000, 0, 1), cp(1500, 1, 1)])]
        let edited = [cue("猫が鳴く", 3000, 4000)]   // +2000 ms
        let merged = SubtitleEditorTimingTools.mergeCheckpoints(into: edited, from: prev)
        XCTAssertEqual(merged[0].checkpoints, [cp(3000, 0, 1), cp(3500, 1, 1)])
    }

    // A checkpoint pushed past the (shrunk) cue end is dropped rather than left dangling.
    func testCheckpointOutOfBoundsAfterShrinkDropped() {
        let prev = [cue("猫が鳴く", 1000, 3000, [cp(1000, 0, 1), cp(2800, 1, 1)])]
        let edited = [cue("猫が鳴く", 1000, 1500)]   // end pulled in; 2800 now out of range
        let merged = SubtitleEditorTimingTools.mergeCheckpoints(into: edited, from: prev)
        XCTAssertEqual(merged[0].checkpoints, [cp(1000, 0, 1)])
    }

    // Inserting a new line must not shift checkpoints off the existing lines: matching is by text
    // content, not index, so line "B" keeps its timing even though its index moved.
    func testInsertedLineDoesNotMisalignByIndex() {
        let prev = [
            cue("A", 0, 1000, [cp(0, 0, 1)]),
            cue("B", 1000, 2000, [cp(1000, 0, 1)]),
        ]
        let edited = [
            cue("A", 0, 1000),
            cue("NEW", 1000, 1500),   // inserted
            cue("B", 1500, 2500),     // same text, shifted later
        ]
        let merged = SubtitleEditorTimingTools.mergeCheckpoints(into: edited, from: prev)
        XCTAssertEqual(merged[0].checkpoints, [cp(0, 0, 1)], "A keeps its checkpoint")
        XCTAssertTrue(merged[1].checkpoints.isEmpty, "inserted line has none")
        XCTAssertEqual(merged[2].checkpoints, [cp(1500, 0, 1)], "B re-anchored by +500, matched by text not index")
    }

    // Duplicate identical lines (chorus refrains) pair front-to-back in time order, so each
    // occurrence adopts its own predecessor's timing rather than all collapsing onto the first.
    func testDuplicateLinesPairInOrder() {
        let prev = [
            cue("ララ", 0, 1000, [cp(100, 0, 2)]),
            cue("ララ", 5000, 6000, [cp(5100, 0, 2)]),
        ]
        let edited = [
            cue("ララ", 0, 1000),
            cue("ララ", 5000, 6000),
        ]
        let merged = SubtitleEditorTimingTools.mergeCheckpoints(into: edited, from: prev)
        XCTAssertEqual(merged[0].checkpoints, [cp(100, 0, 2)])
        XCTAssertEqual(merged[1].checkpoints, [cp(5100, 0, 2)])
    }

    // ♪ non-speech cues never carry checkpoints and are passed through untouched.
    func testNonSpeechCueUntouched() {
        let prev = [cue("猫", 0, 1000, [cp(0, 0, 1)])]
        let edited = [cue("♪", 0, 28000)]
        let merged = SubtitleEditorTimingTools.mergeCheckpoints(into: edited, from: prev)
        XCTAssertTrue(merged[0].checkpoints.isEmpty)
    }

    // A cue that already carries checkpoints is left alone — the merge only fills empties, so it's
    // idempotent and never clobbers freshly-aligned timing.
    func testCueWithExistingCheckpointsLeftUntouched() {
        let prev = [cue("猫", 0, 1000, [cp(0, 0, 1)])]
        let edited = [cue("猫", 0, 1000, [cp(500, 0, 1)])]
        let merged = SubtitleEditorTimingTools.mergeCheckpoints(into: edited, from: prev)
        XCTAssertEqual(merged[0].checkpoints, [cp(500, 0, 1)])
    }
}

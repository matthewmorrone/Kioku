import XCTest
@testable import Kioku

// Pinned tests for the alignment-and-reconcile invariants in docs/INVARIANTS.md.
// Each test references the invariant number from that doc so a future reader can
// trace a regression from a failing test back to the contract it violates.
//
// Scope: pure logic only — matching, gap construction, force-fit, merge. The
// integration path (audio slicing + Whisper inference + cancellation) requires
// a fixture and is covered separately (currently invariant #8, still ❌).
@MainActor
final class SubtitleReconciliationTests: XCTestCase {

    // Builds a speech cue with millisecond timing. Test fixture helper — keeps cases
    // readable by hiding the noisy index/end-vs-start argument permutations.
    private func cue(_ text: String, _ startMs: Int, _ endMs: Int, index: Int = 0) -> SubtitleCue {
        SubtitleCue(index: index, startMs: startMs, endMs: endMs, text: text)
    }

    // MARK: - INVARIANT #2 — Monotonic order
    // matchAnchors must produce note-line indices in non-decreasing order. Chorus
    // refrains (this codebase's torture case: 4× identical "離さないで" lines in the
    // 月色チャイのん lyric) would let a fuzzy/non-monotonic matcher bind the wrong
    // occurrence and twist all subsequent gap windows.

    func testMatchAnchorsProducesMonotonicNoteLineIndices() {
        let noteLines = [
            "離さないで",   // 0
            "二行目",       // 1
            "離さないで",   // 2 — same text as 0
            "四行目",       // 3
        ]
        let cues = [
            cue("離さないで", 0, 1000),
            cue("二行目", 1000, 2000),
            cue("離さないで", 2000, 3000),
            cue("四行目", 3000, 4000),
        ]
        let anchors = SubtitleReconciliation.matchAnchors(speechCues: cues, noteLines: noteLines)
        XCTAssertEqual(anchors.map(\.noteLineIndex), [0, 1, 2, 3],
                       "Each chorus occurrence must bind to its own position, not the first match")
    }

    func testMatchAnchorsSkipsUnmatchedCue() {
        let noteLines = ["A", "B", "C"]
        let cues = [
            cue("A", 0, 1000),
            cue("X", 1000, 2000),   // not in note
            cue("C", 2000, 3000),
        ]
        let anchors = SubtitleReconciliation.matchAnchors(speechCues: cues, noteLines: noteLines)
        XCTAssertEqual(anchors.map(\.noteLineIndex), [0, 2])
        XCTAssertEqual(anchors.map(\.cue.text), ["A", "C"])
    }

    // MARK: - INVARIANT #4 — Idempotence on clean input
    // When every note line has a matching cue with no skipped indices, buildGapWindows
    // returns []. The caller (reconcileFromNote) treats empty gaps as "nothing to do",
    // so running reconcile on a fully-clean SRT must produce zero work.

    func testBuildGapsReturnsEmptyForCompleteAnchorCoverage() {
        let noteLines = ["A", "B", "C"]
        let anchors = [
            MatchedAnchor(cue: cue("A", 0, 1000), noteLineIndex: 0),
            MatchedAnchor(cue: cue("B", 1000, 2000), noteLineIndex: 1),
            MatchedAnchor(cue: cue("C", 2000, 3000), noteLineIndex: 2),
        ]
        let gaps = SubtitleReconciliation.buildGapWindows(
            anchors: anchors, noteLines: noteLines, audioDurationSeconds: 3.0
        )
        XCTAssertTrue(gaps.isEmpty, "Complete anchor coverage must produce zero gap windows")
    }

    // MARK: - INVARIANT #7 — Anchor consumption is contiguous
    // A middle/tail gap consumes its preceding anchor: the anchor's text reappears as
    // the first line in the gap's script, and consumedAnchorIndex points to that anchor
    // so the merger can drop it. Without this, the merger would keep the swallowed-
    // suspect anchor alongside its replacement and produce overlapping cues.

    func testMiddleGapConsumesPrecedingAnchor() {
        let noteLines = ["A", "B", "C", "D"]
        let anchors = [
            MatchedAnchor(cue: cue("A", 0, 1000), noteLineIndex: 0),
            // Note line "B" and "C" are missing — gap should consume anchor 0 ("A")
            MatchedAnchor(cue: cue("D", 5000, 6000), noteLineIndex: 3),
        ]
        let gaps = SubtitleReconciliation.buildGapWindows(
            anchors: anchors, noteLines: noteLines, audioDurationSeconds: 7.0
        )
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].lines, ["A", "B", "C"], "Gap script must lead with the consumed anchor's text")
        XCTAssertEqual(gaps[0].consumedAnchorIndex, 0)
        XCTAssertEqual(gaps[0].audioStart, 0.0, "Gap window must extend back to the consumed anchor's start")
        XCTAssertEqual(gaps[0].audioEnd, 5.0, "Gap window must end at the next anchor's start")
    }

    func testTailGapConsumesLastAnchor() {
        let noteLines = ["A", "B", "C"]
        let anchors = [
            MatchedAnchor(cue: cue("A", 0, 1000), noteLineIndex: 0),
        ]
        let gaps = SubtitleReconciliation.buildGapWindows(
            anchors: anchors, noteLines: noteLines, audioDurationSeconds: 10.0
        )
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].lines, ["A", "B", "C"])
        XCTAssertEqual(gaps[0].consumedAnchorIndex, 0)
        XCTAssertEqual(gaps[0].audioStart, 0.0)
        XCTAssertEqual(gaps[0].audioEnd, 10.0)
    }

    func testHeadGapDoesNotConsumeAnyAnchor() {
        // Head gap is bounded by (0, first_anchor.start) with no anchor before it to
        // consume. The first anchor stays in the output.
        let noteLines = ["A", "B", "C"]
        let anchors = [
            MatchedAnchor(cue: cue("C", 5000, 6000), noteLineIndex: 2),
        ]
        let gaps = SubtitleReconciliation.buildGapWindows(
            anchors: anchors, noteLines: noteLines, audioDurationSeconds: 7.0
        )
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].lines, ["A", "B"])
        XCTAssertNil(gaps[0].consumedAnchorIndex, "Head gap must not consume any anchor")
        XCTAssertEqual(gaps[0].audioStart, 0.0)
        XCTAssertEqual(gaps[0].audioEnd, 5.0)
    }

    // MARK: - INVARIANT #5 — Force-fit completeness
    // uniformDistribute is the safety net for #1 (no-drop) when the aligner can't
    // produce one cue per input line. It must return exactly `lines.count` cues whose
    // combined coverage fills the window with no gaps.

    func testUniformDistributeReturnsExactlyNCues() {
        let cues = SubtitleReconciliation.uniformDistribute(
            lines: ["A", "B", "C", "D"], windowStartMs: 0, windowEndMs: 1000
        )
        XCTAssertEqual(cues.count, 4)
        XCTAssertEqual(cues.map(\.text), ["A", "B", "C", "D"])
    }

    func testUniformDistributeCoversFullWindow() {
        let cues = SubtitleReconciliation.uniformDistribute(
            lines: ["A", "B", "C"], windowStartMs: 1000, windowEndMs: 4000
        )
        XCTAssertEqual(cues.first?.startMs, 1000, "First cue must start at windowStartMs")
        XCTAssertEqual(cues.last?.endMs, 4000, "Last cue must end at windowEndMs")
    }

    func testUniformDistributeHandlesSingleLine() {
        let cues = SubtitleReconciliation.uniformDistribute(
            lines: ["Only"], windowStartMs: 500, windowEndMs: 2500
        )
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].startMs, 500)
        XCTAssertEqual(cues[0].endMs, 2500)
    }

    func testUniformDistributeReturnsEmptyForNoLines() {
        let cues = SubtitleReconciliation.uniformDistribute(
            lines: [], windowStartMs: 0, windowEndMs: 1000
        )
        XCTAssertTrue(cues.isEmpty)
    }

    func testUniformDistributeHandlesZeroWidthWindow() {
        // Force-fit must still return N cues even when the window has no room — every
        // line still gets a representation, per the no-drop invariant. Cues collapse
        // to 1ms each via the per=max(1,...) guard so they remain syntactically valid.
        let cues = SubtitleReconciliation.uniformDistribute(
            lines: ["A", "B", "C"], windowStartMs: 1000, windowEndMs: 1000
        )
        XCTAssertEqual(cues.count, 3, "No-drop must hold even on zero-width windows")
        XCTAssertEqual(cues.map(\.text), ["A", "B", "C"])
    }

    // MARK: - INVARIANT #3 — Anchor non-disturbance
    // Anchors not consumed by any gap must appear in the merged output with their
    // original timings byte-identical. Users learn cue positions; arbitrary shifts
    // during a targeted fix erode trust.

    func testMergePreservesNonConsumedAnchorTimings() {
        let anchors = [
            MatchedAnchor(cue: cue("A", 100, 1100), noteLineIndex: 0),
            MatchedAnchor(cue: cue("B", 2000, 3000), noteLineIndex: 1),
            MatchedAnchor(cue: cue("C", 4000, 5000), noteLineIndex: 2),
        ]
        // Only anchor 1 ("B") is consumed by some hypothetical gap.
        let merged = SubtitleReconciliation.mergeReconciledCues(
            anchors: anchors,
            consumedAnchorIndices: [1],
            musicCues: [],
            newGapCues: [cue("B-new", 2500, 3500)]
        )
        // A and C should be present with their exact original timings.
        let aOut = merged.first { $0.text == "A" }
        let cOut = merged.first { $0.text == "C" }
        XCTAssertEqual(aOut?.startMs, 100)
        XCTAssertEqual(aOut?.endMs, 1100)
        XCTAssertEqual(cOut?.startMs, 4000)
        XCTAssertEqual(cOut?.endMs, 5000)
    }

    // MARK: - INVARIANT #6 — Music preservation
    // ♪ cues reflect VAD-detected non-vocal audio; reconcile works from text only and
    // has no business adjusting them. They pass through to the output unchanged.

    func testMergePreservesMusicCuesUnchanged() {
        let music = [
            cue("♪", 0, 1000),
            cue("♪", 5000, 6000),
        ]
        let merged = SubtitleReconciliation.mergeReconciledCues(
            anchors: [],
            consumedAnchorIndices: [],
            musicCues: music,
            newGapCues: []
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].text, "♪")
        XCTAssertEqual(merged[0].startMs, 0)
        XCTAssertEqual(merged[0].endMs, 1000)
        XCTAssertEqual(merged[1].text, "♪")
        XCTAssertEqual(merged[1].startMs, 5000)
        XCTAssertEqual(merged[1].endMs, 6000)
    }

    // MARK: - INVARIANT #7 (merge side) — Consumed anchors don't appear in output
    // The merger's job is to drop anchors whose indices appear in consumedAnchorIndices;
    // their text reappears via newGapCues. Without this, the swallowed-suspect cue
    // would be present alongside its replacement, producing duplicate/overlapping cues.

    func testMergeOmitsConsumedAnchors() {
        let anchors = [
            MatchedAnchor(cue: cue("kept", 0, 1000), noteLineIndex: 0),
            MatchedAnchor(cue: cue("consumed", 2000, 4000), noteLineIndex: 1),
        ]
        let merged = SubtitleReconciliation.mergeReconciledCues(
            anchors: anchors,
            consumedAnchorIndices: [1],
            musicCues: [],
            newGapCues: [
                cue("consumed", 2000, 2500),   // re-aligned version
                cue("missing", 2500, 4000),
            ]
        )
        XCTAssertEqual(merged.map(\.text), ["kept", "consumed", "missing"])
        // The consumed anchor at 2000-4000 must NOT appear with that range; only the
        // re-aligned version at 2000-2500 should.
        let consumedCues = merged.filter { $0.text == "consumed" }
        XCTAssertEqual(consumedCues.count, 1, "Consumed anchor must appear exactly once (the re-aligned version)")
        XCTAssertEqual(consumedCues[0].startMs, 2000)
        XCTAssertEqual(consumedCues[0].endMs, 2500, "Re-aligned version replaces the original timing")
    }

    func testMergeSortsCuesByStartTime() {
        let merged = SubtitleReconciliation.mergeReconciledCues(
            anchors: [
                MatchedAnchor(cue: cue("third", 3000, 4000), noteLineIndex: 0),
                MatchedAnchor(cue: cue("first", 0, 1000), noteLineIndex: 1),
            ],
            consumedAnchorIndices: [],
            musicCues: [cue("♪", 1500, 2500)],
            newGapCues: [cue("fourth", 5000, 6000)]
        )
        XCTAssertEqual(merged.map(\.text), ["first", "♪", "third", "fourth"])
        // Indices renumbered sequentially after sort.
        XCTAssertEqual(merged.map(\.index), [1, 2, 3, 4])
    }

    // MARK: - cueMatchesNoteLine specifics
    // Conservative matching: exact equality first, NFKC + whitespace-strip exact as
    // fallback. No fuzzy matching.

    func testCueMatchesNoteLineExactMatch() {
        XCTAssertTrue(SubtitleReconciliation.cueMatchesNoteLine("朽ちた花びらに黄昏の翅が", "朽ちた花びらに黄昏の翅が"))
    }

    func testCueMatchesNoteLineWithStraySpace() {
        // Whitespace normalization handles "stray space at end" — a common
        // copy-paste/SRT-export artifact that exact-only matching would miss.
        XCTAssertTrue(SubtitleReconciliation.cueMatchesNoteLine("朽ちた花びらに黄昏の翅が ", "朽ちた花びらに黄昏の翅が"))
    }

    func testCueMatchesNoteLineRejectsSubstring() {
        // Non-fuzzy: a substring match must NOT succeed. Substring matching here would
        // let "朽ちた" match "朽ちた花びらに黄昏の翅が" and twist the anchor walk.
        XCTAssertFalse(SubtitleReconciliation.cueMatchesNoteLine("朽ちた", "朽ちた花びらに黄昏の翅が"))
    }

    func testCueMatchesNoteLineRejectsDifferentText() {
        XCTAssertFalse(SubtitleReconciliation.cueMatchesNoteLine("ABC", "XYZ"))
    }

    // MARK: - INVARIANT #1 — No-drop (composed)
    // Composing matching → gap construction → uniformDistribute → merge with input
    // where ZERO cues match the note text. Every note line must appear in the output.
    // This is the worst case: brand-new note text vs. an unrelated SRT.

    func testReconcilePipelineDropsNoLinesOnTotalMismatch() {
        let noteLines = ["新1行目", "新2行目", "新3行目"]
        let speechCues = [
            cue("古い1行目", 0, 1000),
            cue("古い2行目", 2000, 3000),
        ]
        let anchors = SubtitleReconciliation.matchAnchors(speechCues: speechCues, noteLines: noteLines)
        XCTAssertTrue(anchors.isEmpty, "No anchors when no text matches")

        let gaps = SubtitleReconciliation.buildGapWindows(
            anchors: anchors, noteLines: noteLines, audioDurationSeconds: 4.0
        )
        XCTAssertEqual(gaps.count, 1, "Total mismatch produces one head gap covering the whole audio")
        XCTAssertEqual(gaps[0].lines, ["新1行目", "新2行目", "新3行目"])

        // Simulate the force-fit path: aligner returned nothing usable, so the caller
        // falls back to uniform distribution.
        let forced = SubtitleReconciliation.uniformDistribute(
            lines: gaps[0].lines,
            windowStartMs: Int(gaps[0].audioStart * 1000),
            windowEndMs: Int(gaps[0].audioEnd * 1000)
        )
        let merged = SubtitleReconciliation.mergeReconciledCues(
            anchors: anchors,
            consumedAnchorIndices: [],
            musicCues: [],
            newGapCues: forced
        )
        let outputTexts = merged.map(\.text)
        for noteLine in noteLines {
            XCTAssertTrue(outputTexts.contains(noteLine), "No-drop: \(noteLine) must appear in output")
        }
    }
}

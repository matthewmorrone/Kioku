import XCTest
@testable import Kioku

// Characterizes SongLineCard.estimatedActiveWordRange: the heuristic that maps Listen-along's
// progress through a sentence's cue onto one of the Read tab's segmented words, so the
// narrated line can highlight the word being spoken instead of just the whole line.
// AVSpeechSynthesizer's buffer-based rendering never reports real per-word timing, so this is
// a proportional-by-character-count estimate, not measured timing.
@MainActor
final class SongLineCardTests: XCTestCase {
    // "君" (1) / "の" (1) / "名前" (2) — total length 4, so each single-character word covers
    // a 0.25 slice of progress and the two-character word covers the remaining 0.5.
    private let text = "君の名前"

    private func ranges(_ lengths: [Int]) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex
        for length in lengths {
            let end = text.index(cursor, offsetBy: length)
            ranges.append(cursor..<end)
            cursor = end
        }
        return ranges
    }

    func testEmptySegmentationRangesReturnsNil() {
        XCTAssertNil(SongLineCard.estimatedActiveWordRange(progress: 0.5, segmentationRanges: [], in: text))
    }

    func testProgressAtStartSelectsFirstWord() {
        let result = SongLineCard.estimatedActiveWordRange(progress: 0.0, segmentationRanges: ranges([1, 1, 2]), in: text)
        XCTAssertEqual(result, NSRange(location: 0, length: 1))
    }

    func testProgressJustBeforeBoundaryStaysOnFirstWord() {
        // Offset 0.96 of 4 total chars = 0.96, still inside the first word's [0,1) span.
        let result = SongLineCard.estimatedActiveWordRange(progress: 0.24, segmentationRanges: ranges([1, 1, 2]), in: text)
        XCTAssertEqual(result, NSRange(location: 0, length: 1))
    }

    func testProgressJustAfterBoundaryMovesToSecondWord() {
        // Offset 1.04 of 4 total chars, just past the first word's [0,1) span.
        let result = SongLineCard.estimatedActiveWordRange(progress: 0.26, segmentationRanges: ranges([1, 1, 2]), in: text)
        XCTAssertEqual(result, NSRange(location: 1, length: 1))
    }

    func testProgressNearEndSelectsLastWord() {
        let result = SongLineCard.estimatedActiveWordRange(progress: 0.9, segmentationRanges: ranges([1, 1, 2]), in: text)
        XCTAssertEqual(result, NSRange(location: 2, length: 2))
    }

    // Progress of exactly 1.0 (or anything >= 1) is clamped below 1 before scaling, so it never
    // walks off the end of the ranges array.
    func testProgressAtOrAboveOneClampsToLastWord() {
        let atOne = SongLineCard.estimatedActiveWordRange(progress: 1.0, segmentationRanges: ranges([1, 1, 2]), in: text)
        let wellPast = SongLineCard.estimatedActiveWordRange(progress: 5.0, segmentationRanges: ranges([1, 1, 2]), in: text)
        XCTAssertEqual(atOne, NSRange(location: 2, length: 2))
        XCTAssertEqual(wellPast, NSRange(location: 2, length: 2))
    }

    // Negative progress (shouldn't happen, but the function clamps defensively) lands on the
    // first word rather than producing a nonsensical negative offset.
    func testNegativeProgressClampsToFirstWord() {
        let result = SongLineCard.estimatedActiveWordRange(progress: -0.5, segmentationRanges: ranges([1, 1, 2]), in: text)
        XCTAssertEqual(result, NSRange(location: 0, length: 1))
    }

    // A single word spanning the whole line always wins, regardless of progress.
    func testSingleWordCoveringWholeLineAlwaysWins() {
        let whole = ranges([4])
        XCTAssertEqual(SongLineCard.estimatedActiveWordRange(progress: 0.0, segmentationRanges: whole, in: text), NSRange(location: 0, length: 4))
        XCTAssertEqual(SongLineCard.estimatedActiveWordRange(progress: 0.99, segmentationRanges: whole, in: text), NSRange(location: 0, length: 4))
    }
}

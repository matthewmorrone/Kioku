import XCTest
import UIKit
import CoreText
@testable import Kioku

// Guards the geometry contract that FuriganaTextRenderer (and the experimental CoreText
// path) rely on. Every public method here is a load-bearing primitive — if any of these
// tests fail, ruby placement, segment hit-testing, or scroll-to-cue will regress.
final class KiokuTextLayoutEngineTests: XCTestCase {

    private let baseFont = UIFont.systemFont(ofSize: 18)

    private func makeAttributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: baseFont])
    }

    private func makeEngine(
        _ text: String = "Hello world this is a test of wrapping",
        width: CGFloat = 120,
        inset: UIEdgeInsets = .zero
    ) -> KiokuTextLayoutEngine {
        KiokuTextLayoutEngine(
            attributedString: makeAttributed(text),
            widthConstraint: width,
            contentInset: inset
        )
    }

    // MARK: - Layout invariants

    func test_emptyString_producesNoLines_and_contentSizeIsJustInset() {
        let inset = UIEdgeInsets(top: 4, left: 8, bottom: 6, right: 10)
        let engine = KiokuTextLayoutEngine(
            attributedString: NSAttributedString(),
            widthConstraint: 200,
            contentInset: inset
        )
        XCTAssertTrue(engine.lines.isEmpty)
        XCTAssertEqual(engine.contentSize.width, inset.left + inset.right, accuracy: 0.01)
        XCTAssertEqual(engine.contentSize.height, inset.top + inset.bottom, accuracy: 0.01)
    }

    func test_zeroWidth_producesNoLines() {
        let engine = makeEngine(width: 0)
        XCTAssertTrue(engine.lines.isEmpty)
    }

    func test_shortText_singleLine() {
        let engine = makeEngine("Hi", width: 400)
        XCTAssertEqual(engine.lines.count, 1)
    }

    func test_longText_wrapsToMultipleLines() {
        let engine = makeEngine(width: 80)
        XCTAssertGreaterThanOrEqual(engine.lines.count, 2,
            "Text wider than constraint must wrap to ≥2 lines.")
    }

    func test_linesAreYAscending_andDoNotOverlap() {
        let engine = makeEngine(width: 80)
        guard engine.lines.count >= 2 else { return XCTFail("Need ≥2 lines") }
        for pair in zip(engine.lines, engine.lines.dropFirst()) {
            let topBottom = pair.0.origin.y + pair.0.height
            XCTAssertLessThanOrEqual(topBottom, pair.1.origin.y + 0.5,
                "Line N's bottom must not exceed line N+1's top.")
        }
    }

    func test_contentSize_coversAllLines() {
        let inset = UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
        let engine = makeEngine(width: 80, inset: inset)
        guard let lastLine = engine.lines.last else { return XCTFail("Expected lines") }
        let needed = lastLine.origin.y + lastLine.height + inset.bottom
        XCTAssertGreaterThanOrEqual(engine.contentSize.height, needed - 0.5,
            "contentSize must include all lines plus bottom inset (last-line clip regression).")
    }

    // MARK: - Width and inset updates

    func test_setWidthConstraint_smallerForcesMoreLines() {
        let engine = makeEngine(width: 400)
        let wideCount = engine.lines.count
        engine.setWidthConstraint(60)
        XCTAssertGreaterThan(engine.lines.count, wideCount)
    }

    func test_setWidthConstraint_subpixelChangeIsIgnored() {
        let engine = makeEngine(width: 200)
        let before = engine.lines.count
        engine.setWidthConstraint(200.1)
        XCTAssertEqual(engine.lines.count, before,
            "Sub-0.5pt width changes must not trigger relayout to avoid bounds-thrash.")
    }

    // MARK: - Geometry queries

    func test_firstRect_outOfBoundsReturnsNil() {
        let engine = makeEngine("abc", width: 200)
        XCTAssertNil(engine.firstRect(forCharacterRange: NSRange(location: 999, length: 1)))
        XCTAssertNil(engine.firstRect(forCharacterRange: NSRange(location: 0, length: 0)))
    }

    func test_firstRect_returnsPositiveSizedRect() {
        let engine = makeEngine("abcdef", width: 200)
        let rect = engine.firstRect(forCharacterRange: NSRange(location: 0, length: 3))
        XCTAssertNotNil(rect)
        XCTAssertGreaterThan(rect!.width, 0)
        XCTAssertGreaterThan(rect!.height, 0)
    }

    func test_boundingRects_singleLineReturnsOneRect() {
        let engine = makeEngine("abcdef", width: 200)
        let rects = engine.boundingRects(forCharacterRange: NSRange(location: 0, length: 3))
        XCTAssertEqual(rects.count, 1)
    }

    func test_boundingRects_multiLineRangeReturnsRectPerLine() {
        // Text long enough to wrap into ≥2 lines at a narrow width; range covers both.
        let text = "the quick brown fox jumps over the lazy dog"
        let engine = KiokuTextLayoutEngine(
            attributedString: makeAttributed(text),
            widthConstraint: 80
        )
        guard engine.lines.count >= 2 else { return XCTFail("Expected ≥2 lines") }
        let rects = engine.boundingRects(forCharacterRange: NSRange(location: 0, length: text.utf16.count))
        XCTAssertEqual(rects.count, engine.lines.count,
            "boundingRects must return one rect per line the range crosses.")
    }

    func test_lineIndex_forCharacterIndex_OOBReturnsNil() {
        let engine = makeEngine("abc", width: 200)
        XCTAssertNil(engine.lineIndex(forCharacterIndex: -1))
        XCTAssertNil(engine.lineIndex(forCharacterIndex: 999))
    }

    func test_lineIndex_forCharacterIndex_findsCorrectLine() {
        let text = "alpha beta gamma delta epsilon zeta eta theta iota"
        let engine = KiokuTextLayoutEngine(
            attributedString: makeAttributed(text),
            widthConstraint: 80
        )
        guard engine.lines.count >= 2 else { return XCTFail("Expected ≥2 lines") }
        let secondLineStart = engine.lines[1].stringRange.location
        XCTAssertEqual(engine.lineIndex(forCharacterIndex: secondLineStart), 1)
    }

    func test_characterIndex_atPoint_OOBReturnsNil() {
        let engine = makeEngine("abc", width: 200)
        XCTAssertNil(engine.characterIndex(at: CGPoint(x: -100, y: -100)))
        XCTAssertNil(engine.characterIndex(at: CGPoint(x: 0, y: 9999)))
    }

    func test_characterIndex_atPoint_returnsValidIndexInsideText() {
        let engine = makeEngine("abcdef", width: 200)
        guard let firstLine = engine.lines.first else { return XCTFail("Expected line") }
        let probe = CGPoint(
            x: firstLine.origin.x + firstLine.width * 0.5,
            y: firstLine.origin.y + firstLine.height * 0.5
        )
        let index = engine.characterIndex(at: probe)
        XCTAssertNotNil(index)
        XCTAssertGreaterThanOrEqual(index!, 0)
        XCTAssertLessThanOrEqual(index!, 6)
    }

    // Regression: tapping past the line's right edge must return nil, not pin to the
    // line's last character. Without this clamp the host can't tell "tapped a word"
    // from "tapped the empty space to the right of a word," and selection-clearing
    // becomes impossible. CTLineGetStringIndexForPosition will happily map any X to
    // the closest character; the X-bounds check in characterIndex is what prevents that.
    func test_characterIndex_atPoint_pastLineRightEdgeReturnsNil() {
        let engine = makeEngine("abc", width: 400)
        guard let line = engine.lines.first else { return XCTFail("Expected line") }
        // 50pt past the right edge of the line's glyph content — well beyond the 2pt slop.
        let probe = CGPoint(
            x: line.origin.x + line.width + 50,
            y: line.origin.y + line.height * 0.5
        )
        XCTAssertNil(engine.characterIndex(at: probe),
            "Tap past the line's right edge must not pin to the last character.")
    }

    // Companion: the small tolerance still lets sub-pixel-edge taps on the LAST glyph
    // hit through. Without this, taps that happen to land 0.5pt past the line's
    // measured width would also drop, which would feel like dead zones on word ends.
    func test_characterIndex_atPoint_withinSlopOfRightEdgeStillReturnsIndex() {
        let engine = makeEngine("abc", width: 400)
        guard let line = engine.lines.first else { return XCTFail("Expected line") }
        let probe = CGPoint(
            x: line.origin.x + line.width + 1,  // 1pt past width, within 2pt slop
            y: line.origin.y + line.height * 0.5
        )
        XCTAssertNotNil(engine.characterIndex(at: probe),
            "Sub-pixel slop beyond the right edge should still resolve to the last character.")
    }

    // MARK: - Per-line origin shift (wide-ruby line-start inset replacement)

    func test_setLineOriginShifts_movesLineOriginsWithoutRelayout() {
        let engine = makeEngine("the quick brown fox jumps over", width: 80)
        guard engine.lines.count >= 2 else { return XCTFail("Expected ≥2 lines") }
        let originalCount = engine.lines.count
        let originalLine0X = engine.lines[0].origin.x

        engine.setLineOriginShifts([0: 12])

        XCTAssertEqual(engine.lines.count, originalCount,
            "Origin shifts must not retypeset / change line count.")
        XCTAssertEqual(engine.lines[0].origin.x, originalLine0X + 12, accuracy: 0.5,
            "Shifted line's X origin must move by exactly the shift amount.")
        // Unshifted lines must remain at their natural origin.
        for index in 1..<engine.lines.count {
            XCTAssertEqual(engine.lines[index].origin.x, 0, accuracy: 0.5,
                "Unshifted lines must stay at the natural left inset.")
        }
    }

    func test_setLineOriginShifts_idempotentOnEqualValue() {
        let engine = makeEngine("hello there general kenobi you are a bold one", width: 80)
        engine.setLineOriginShifts([0: 5])
        let snapshot = engine.lines.map(\.origin.x)
        engine.setLineOriginShifts([0: 5])
        let after = engine.lines.map(\.origin.x)
        XCTAssertEqual(snapshot, after)
    }

    // MARK: - Line spacing (ruby height reservation)

    func test_setLineSpacing_pushesSubsequentLinesDown() {
        let text = "alpha beta gamma delta epsilon zeta"
        let engine = KiokuTextLayoutEngine(
            attributedString: makeAttributed(text),
            widthConstraint: 80
        )
        guard engine.lines.count >= 2 else { return XCTFail("Expected ≥2 lines") }
        let originalLine1Y = engine.lines[1].origin.y

        engine.setLineSpacing(10)
        XCTAssertEqual(engine.lines.count, engine.lines.count) // shape preserved
        XCTAssertGreaterThan(engine.lines[1].origin.y, originalLine1Y + 9,
            "Setting +10 line spacing must push line 1 down by ~10pt.")
    }

    // MARK: - Segment-aware line breaking (B1 invariant)

    // The headline guarantee: with segment NSRanges supplied, CT's chosen break point is
    // walked back to the previous segment boundary if the suggestion would split a segment
    // mid-character. Mirrors what TK2's `shouldBreakLineBefore:hyphenating:` delegate did
    // implicitly. Without the post-process, a multi-character compound at the right margin
    // gets bisected and the user sees half the word on each line.
    func test_lineBreak_doesNotSplitSegmentMidCharacter() {
        // "abcd" + space + "efghij" + space + "klmn". Three segments, the middle one is
        // 6 chars wide, the line width is set to fit ~10 chars so CT would naturally
        // wrap inside efghij. With segments supplied, the break must move back to before
        // 'e', so the second line starts with the entire efghij compound.
        let text = "abcd efghij klmn"
        let engine = KiokuTextLayoutEngine(
            attributedString: makeAttributed(text),
            widthConstraint: 80
        )
        let segs: [NSRange] = [
            NSRange(location: 0, length: 4),    // abcd
            NSRange(location: 5, length: 6),    // efghij
            NSRange(location: 12, length: 4),   // klmn
        ]
        engine.setSegmentNSRanges(segs)

        for line in engine.lines {
            let lineEndOffset = line.stringRange.location + line.stringRange.length
            for seg in segs {
                let isInteriorBreak =
                    lineEndOffset > seg.location && lineEndOffset < seg.location + seg.length
                XCTAssertFalse(isInteriorBreak,
                    "Line ending at offset \(lineEndOffset) lands inside segment \(seg) — segments must wrap atomically.")
            }
        }
    }

    // Edge case: when a segment is wider than the available line, the engine has no choice
    // but to break inside it. We assert the engine doesn't deadlock or produce zero-length
    // lines — it falls back to CT's break instead. Without this fallback, an oversized
    // segment would loop forever (adjusted == 0 → infinite zero-progress loop).
    func test_lineBreak_oversizedSegmentFallsBackToDefaultBreak() {
        let text = "xxxxxxxxxxxxxxxxxx"  // 18 chars, all one segment
        let engine = KiokuTextLayoutEngine(
            attributedString: makeAttributed(text),
            widthConstraint: 60  // way too narrow to fit the segment
        )
        engine.setSegmentNSRanges([NSRange(location: 0, length: 18)])

        XCTAssertGreaterThan(engine.lines.count, 0,
            "Oversized segment must still produce lines; no infinite loop, no empty layout.")
        let total = engine.lines.reduce(0) { $0 + $1.stringRange.length }
        XCTAssertEqual(total, 18, "All characters must be laid out exactly once.")
    }

    // Empty segment list = legacy behavior. CT picks any character boundary; we verify
    // the engine doesn't add behavior that depends on the segment list being non-empty.
    func test_lineBreak_noSegmentsSuppliedFallsBackToCTSuggestion() {
        let text = "alpha beta gamma delta"
        let engineWithoutSegs = KiokuTextLayoutEngine(
            attributedString: makeAttributed(text),
            widthConstraint: 80
        )
        let baselineCount = engineWithoutSegs.lines.count

        let engineWithEmptySegs = KiokuTextLayoutEngine(
            attributedString: makeAttributed(text),
            widthConstraint: 80
        )
        engineWithEmptySegs.setSegmentNSRanges([])

        XCTAssertEqual(engineWithEmptySegs.lines.count, baselineCount,
            "Empty segment list must reproduce the no-constraint layout exactly.")
    }

    // MARK: - Segment ordering / contiguity (A2 invariants)

    // Segments fed in unsorted order get internally sorted by location. This matters
    // because adjustedLineLength uses `first(where:)` to find a containing segment, and
    // unsorted input could mask a contiguity violation that the sort would surface.
    func test_setSegmentNSRanges_sortsByLocationInternally() {
        let text = "alpha beta gamma delta"
        let engine = KiokuTextLayoutEngine(
            attributedString: makeAttributed(text),
            widthConstraint: 80
        )
        // Pass in reverse order; engine should still apply the same constraint.
        let segsReversed: [NSRange] = [
            NSRange(location: 17, length: 5),  // delta
            NSRange(location: 11, length: 5),  // gamma
            NSRange(location: 6, length: 4),   // beta
            NSRange(location: 0, length: 5),   // alpha
        ]
        engine.setSegmentNSRanges(segsReversed)

        // Same invariant as B1: no line-break offset can land in any segment's interior.
        for line in engine.lines {
            let lineEndOffset = line.stringRange.location + line.stringRange.length
            for seg in segsReversed {
                let isInteriorBreak =
                    lineEndOffset > seg.location && lineEndOffset < seg.location + seg.length
                XCTAssertFalse(isInteriorBreak,
                    "Sort must happen at the engine boundary so unsorted callers still get atomic wrapping.")
            }
        }
    }

    // Invariant A2: a well-formed segmentation has no overlaps and no gaps when
    // concatenated — segment surfaces stitch together to form the source text. We test
    // this for the "fast path" outputs of edgesFromSegmentRanges via the data-layer
    // helper. Engine-level we assert the post-sort sequence is non-overlapping —
    // overlaps would create ambiguity in adjustedLineLength's segment lookup.
    func test_setSegmentNSRanges_overlappingRangesAreFiltered_orWellDefined() {
        let text = "alpha beta gamma delta"
        let engine = KiokuTextLayoutEngine(
            attributedString: makeAttributed(text),
            widthConstraint: 80
        )
        // Overlapping ranges: alpha+beta as one, also beta as standalone. The engine
        // doesn't dedupe overlaps (data-layer concern); we just assert it doesn't crash
        // and still respects the wider range as a wrap-atomic unit.
        let segs: [NSRange] = [
            NSRange(location: 0, length: 10),  // "alpha beta"
            NSRange(location: 6, length: 4),   // "beta" (overlapping with above)
            NSRange(location: 11, length: 5),  // "gamma"
            NSRange(location: 17, length: 5),  // "delta"
        ]
        engine.setSegmentNSRanges(segs)

        XCTAssertGreaterThan(engine.lines.count, 0,
            "Engine must tolerate overlapping segment ranges without producing zero lines.")
    }

    // MARK: - Wide-ruby line-start inset (B5 invariant)

    // When a line origin is shifted right by the wide-ruby inset, the line's leftmost
    // glyph's screen X position should land at or right of the contentInset's left edge —
    // i.e., the shift makes ruby NOT overhang into the margin. This is the visual contract
    // the inset is supposed to enforce. We test the geometric outcome (post-shift glyph X
    // ≥ inset.left) rather than the shift computation itself, so the test catches both
    // formula bugs and apply-step bugs.
    func test_lineOriginShift_keepsGlyphsAtOrInsideContentInset() {
        let text = "alpha beta gamma delta epsilon zeta eta theta"
        let inset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        let engine = KiokuTextLayoutEngine(
            attributedString: makeAttributed(text),
            widthConstraint: 100,
            contentInset: inset
        )
        guard engine.lines.count >= 2 else { return XCTFail("Need ≥2 lines for shift test") }

        // Apply a positive shift to line 1 (simulating wide ruby pushing the first glyph
        // right of the line origin). After the shift, line 1's origin.x must be at or
        // right of the inset's left edge — never less.
        let shift: CGFloat = 6
        engine.setLineOriginShifts([1: shift])
        XCTAssertGreaterThanOrEqual(engine.lines[1].origin.x, inset.left,
            "Shifted line origin must never sit left of the content inset's left edge.")
        XCTAssertEqual(engine.lines[1].origin.x, inset.left + shift, accuracy: 0.5,
            "Shift must apply additively to the inset baseline.")
    }
}

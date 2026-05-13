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
}

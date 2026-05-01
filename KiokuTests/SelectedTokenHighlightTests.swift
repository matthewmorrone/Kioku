import XCTest
import UIKit
@testable import Kioku

// Verifies the selected-token highlight envelope stays correct as text size, ruby width,
// and furigana spacing vary. The envelope math lives in FuriganaSelectedSegmentGeometry
// (extracted from FuriganaTextRenderer specifically so these invariants can be tested
// without spinning up a UITextView in the test target).
final class SelectedTokenHighlightTests: XCTestCase {

    // Stand-in for the TextKit `firstRect(for:)` result a real UITextView would return.
    // The envelope math doesn't care about the rect's origin — only that it is consistent
    // across calls — so a fixed origin is fine.
    private func selectedRect(width: CGFloat, height: CGFloat = 24, x: CGFloat = 16, y: CGFloat = 40) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    // I1: envelope is non-empty for any non-empty surface.
    func testEnvelopeIsNonEmptyForRangeOfSizes() {
        for textSize in stride(from: 14.0, through: 32.0, by: 2.0) {
            let baseFont = UIFont.systemFont(ofSize: CGFloat(textSize))
            let headwordWidth = ceil(("食べる" as NSString).size(withAttributes: [.font: baseFont]).width)
            let envelope = FuriganaSelectedSegmentGeometry.envelopeRect(
                selectedRect: selectedRect(width: headwordWidth),
                surface: "食べる",
                furigana: "たべる",
                textSize: CGFloat(textSize),
                furiganaGap: 4
            )
            XCTAssertGreaterThan(envelope.width, 0, "width must be positive at textSize=\(textSize)")
            XCTAssertGreaterThan(envelope.height, 0, "height must be positive at textSize=\(textSize)")
        }
    }

    // I2: envelope vertical extent equals selected-rect height + furigana row height.
    func testHeightCoversFuriganaRowAcrossSizes() {
        for (textSize, furiganaGap) in [(14.0, 0.0), (17.0, 4.0), (24.0, 8.0), (32.0, 12.0)] {
            let furiganaFont = UIFont.systemFont(ofSize: CGFloat(textSize) * 0.5)
            let expectedRowHeight = furiganaFont.lineHeight + CGFloat(furiganaGap)
            let baseRect = selectedRect(width: 80)
            let envelope = FuriganaSelectedSegmentGeometry.envelopeRect(
                selectedRect: baseRect,
                surface: "力",
                furigana: "ちから",
                textSize: CGFloat(textSize),
                furiganaGap: CGFloat(furiganaGap)
            )
            XCTAssertEqual(envelope.height, baseRect.height + expectedRowHeight, accuracy: 0.001,
                           "height must cover headword + furigana row at textSize=\(textSize) gap=\(furiganaGap)")
            XCTAssertEqual(envelope.minY, baseRect.minY - expectedRowHeight, accuracy: 0.001,
                           "minY must sit above headword by furigana row height")
        }
    }

    // I3: envelope width covers the headword (with the +2pt inset).
    func testWidthCoversHeadwordWidth() {
        for textSize in [14.0, 17.0, 22.0, 28.0] {
            let baseFont = UIFont.systemFont(ofSize: CGFloat(textSize))
            let surface = "食べる"
            let headwordWidth = ceil((surface as NSString).size(withAttributes: [.font: baseFont]).width)
            let envelope = FuriganaSelectedSegmentGeometry.envelopeRect(
                selectedRect: selectedRect(width: headwordWidth),
                surface: surface,
                furigana: nil,
                textSize: CGFloat(textSize),
                furiganaGap: 4
            )
            XCTAssertEqual(envelope.width, headwordWidth + 2, accuracy: 0.001,
                           "width must equal headword + 2pt inset at textSize=\(textSize)")
        }
    }

    // I4: when the furigana ruby is wider than the headword, the envelope expands sideways
    // around the headword's visual midpoint to match FuriganaAttributedString centering.
    func testWideRubyExpandsEnvelopeSymmetrically() {
        let textSize: CGFloat = 20
        let baseFont = UIFont.systemFont(ofSize: textSize)
        let furiganaFont = UIFont.systemFont(ofSize: textSize * 0.5)
        let surface = "力"  // single narrow kanji
        let furigana = "ちから"  // three-kana reading, wider than the kanji
        let headwordWidth = ceil((surface as NSString).size(withAttributes: [.font: baseFont]).width)
        let furiganaWidth = ceil((furigana as NSString).size(withAttributes: [.font: furiganaFont]).width)

        let baseRect = selectedRect(width: headwordWidth)
        let envelope = FuriganaSelectedSegmentGeometry.envelopeRect(
            selectedRect: baseRect,
            surface: surface,
            furigana: furigana,
            textSize: textSize,
            furiganaGap: 4
        )

        XCTAssertGreaterThan(furiganaWidth, headwordWidth, "test premise: ruby must be wider than headword")
        XCTAssertEqual(envelope.width, furiganaWidth + 2, accuracy: 0.001,
                       "wide ruby must drive the envelope width, not the headword")

        let kanjiMidX = baseRect.minX + headwordWidth / 2
        let envelopeMidX = envelope.midX
        XCTAssertEqual(envelopeMidX, kanjiMidX, accuracy: 0.5,
                       "envelope must remain centered on the headword's visual midpoint")
    }

    // I5: when the furigana ruby is narrower than the headword, the headword still drives
    // the width — the envelope can't shrink below the kanji it's wrapping.
    func testNarrowRubyDoesNotShrinkBelowHeadword() {
        let textSize: CGFloat = 20
        let baseFont = UIFont.systemFont(ofSize: textSize)
        let surface = "食べる"
        let furigana = "た"
        let headwordWidth = ceil((surface as NSString).size(withAttributes: [.font: baseFont]).width)

        let envelope = FuriganaSelectedSegmentGeometry.envelopeRect(
            selectedRect: selectedRect(width: headwordWidth),
            surface: surface,
            furigana: furigana,
            textSize: textSize,
            furiganaGap: 4
        )
        XCTAssertEqual(envelope.width, headwordWidth + 2, accuracy: 0.001,
                       "narrow ruby must not shrink the envelope below the headword")
    }

    // I6: doubling the text size doubles the envelope's content footprint within rounding.
    // (System-font kerning isn't perfectly linear so we allow a small slack window.)
    func testEnvelopeScalesProportionallyWithTextSize() {
        let smallSize: CGFloat = 14
        let largeSize: CGFloat = 28
        let baseFont = UIFont.systemFont(ofSize: smallSize)
        let surface = "食べる"
        let smallHeadwordWidth = ceil((surface as NSString).size(withAttributes: [.font: baseFont]).width)
        let largeHeadwordWidth = ceil((surface as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: largeSize)]).width)

        let smallEnvelope = FuriganaSelectedSegmentGeometry.envelopeRect(
            selectedRect: selectedRect(width: smallHeadwordWidth),
            surface: surface, furigana: "たべる",
            textSize: smallSize, furiganaGap: 4
        )
        let largeEnvelope = FuriganaSelectedSegmentGeometry.envelopeRect(
            selectedRect: selectedRect(width: largeHeadwordWidth),
            surface: surface, furigana: "たべる",
            textSize: largeSize, furiganaGap: 4
        )
        let widthRatio = (largeEnvelope.width - 2) / (smallEnvelope.width - 2)
        XCTAssertEqual(widthRatio, 2.0, accuracy: 0.08,
                       "doubling text size should roughly double envelope content width (got \(widthRatio))")
    }

    // I7: changing the furigana gap must move only the vertical extent, never the width or x.
    func testFuriganaGapDoesNotAffectHorizontalGeometry() {
        let baseRect = selectedRect(width: 80)
        let small = FuriganaSelectedSegmentGeometry.envelopeRect(
            selectedRect: baseRect, surface: "食べる", furigana: "たべる",
            textSize: 20, furiganaGap: 0
        )
        let large = FuriganaSelectedSegmentGeometry.envelopeRect(
            selectedRect: baseRect, surface: "食べる", furigana: "たべる",
            textSize: 20, furiganaGap: 16
        )
        XCTAssertEqual(small.minX, large.minX, accuracy: 0.001,
                       "furiganaGap must not affect horizontal origin")
        XCTAssertEqual(small.width, large.width, accuracy: 0.001,
                       "furiganaGap must not affect width")
        XCTAssertGreaterThan(large.height, small.height,
                             "larger gap must produce taller envelope")
    }
}

import XCTest
import UIKit
@testable import Kioku

// Guards the dev-only debug overlay geometry. The most load-bearing invariant here is
// the BISECTOR CORRECTNESS: the headword bisector must lie at the geometric center
// of the rendered kanji, and the furigana bisector must coincide with it (because
// CTRubyAnnotation `.center` aligns ruby midpoint over base midpoint). A regression
// in either would make the overlay lie about glyph positions, which defeats its
// entire purpose as a debugging aid.
final class KiokuDebugOverlayGeometryTests: XCTestCase {

    private let baseFont = UIFont.systemFont(ofSize: 18)
    private let furiFont = UIFont.systemFont(ofSize: 9)

    private func makeInputs(
        rects: [NSRange: CGRect],
        ranges: [NSRange],
        readings: [Int: String] = [:],
        lines: [CGRect] = [],
        bandHeight: CGFloat = 12
    ) -> KiokuDebugOverlayGeometry.Inputs {
        // For the test: assume each segment with a reading is itself a single kanji-run
        // covering the whole segment. That mirrors what the renderer passes for simple
        // single-kanji segments. Tests covering multi-char segments with embedded
        // kanji-runs can override this by passing kanjiRunRectByLocation explicitly.
        var kanjiRunRects: [Int: CGRect] = [:]
        var kanjiRunLengths: [Int: Int] = [:]
        for r in ranges {
            if readings[r.location] != nil, let rect = rects[r] {
                kanjiRunRects[r.location] = rect
                kanjiRunLengths[r.location] = r.length
            }
        }
        return .init(
            firstRectByNSRange: rects,
            segmentNSRanges: ranges,
            kanjiRunRectByLocation: kanjiRunRects,
            kanjiRunLengthByLocation: kanjiRunLengths,
            readingByLocation: readings,
            baseFont: baseFont,
            furiganaFont: furiFont,
            lineFrames: lines,
            furiganaBandHeight: bandHeight
        )
    }

    // MARK: - Bisector correctness

    func test_bisectorX_isMidXOfHeadwordRect() {
        // Headword rect at x=10, width=30 → midX = 25
        let range = NSRange(location: 0, length: 1)
        let inputs = makeInputs(
            rects: [range: CGRect(x: 10, y: 100, width: 30, height: 24)],
            ranges: [range]
        )
        let segments = KiokuDebugOverlayGeometry.segments(inputs)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].bisectorX, 25, accuracy: 0.01,
            "Bisector must be the midX of the rect returned by the engine's firstRect — anything else would drift relative to the rendered glyphs.")
    }

    func test_bisectorX_coincides_for_headword_and_furigana_byConstruction() {
        // CTRubyAnnotation `.center` puts ruby midpoint over base midpoint. We assert
        // that property here so any future change that breaks the assumption surfaces
        // as a test failure (not as a silently-wrong overlay).
        let range = NSRange(location: 0, length: 1)
        let inputs = makeInputs(
            rects: [range: CGRect(x: 50, y: 200, width: 24, height: 24)],
            ranges: [range],
            readings: [0: "ねこ"]
        )
        let seg = KiokuDebugOverlayGeometry.segments(inputs).first!
        XCTAssertNotNil(seg.furiganaRect)
        XCTAssertEqual(seg.furiganaRect!.midX, seg.bisectorX, accuracy: 0.01,
            "Ruby midX must equal headword midX. If this drifts, the bisector lies.")
    }

    // MARK: - Furigana rect placement

    func test_furiganaRect_sitsAboveHeadword() {
        let range = NSRange(location: 0, length: 1)
        let headword = CGRect(x: 50, y: 200, width: 24, height: 24)
        let inputs = makeInputs(
            rects: [range: headword],
            ranges: [range],
            readings: [0: "ね"]
        )
        let seg = KiokuDebugOverlayGeometry.segments(inputs).first!
        let furi = seg.furiganaRect!
        XCTAssertEqual(furi.maxY, seg.headwordRect.minY, accuracy: 0.01,
            "Ruby's bottom edge sits flush against the (standardized) headword's top — gap is reserved by lineSpacing in the engine.")
    }

    func test_noReading_furiganaRectIsNil() {
        let range = NSRange(location: 0, length: 1)
        let inputs = makeInputs(
            rects: [range: CGRect(x: 0, y: 0, width: 24, height: 24)],
            ranges: [range],
            readings: [:]
        )
        let seg = KiokuDebugOverlayGeometry.segments(inputs).first!
        XCTAssertNil(seg.furiganaRect)
    }

    // MARK: - Envelope

    func test_envelope_unionOfHeadwordAndFurigana() {
        let range = NSRange(location: 0, length: 1)
        let headword = CGRect(x: 50, y: 200, width: 24, height: 24)
        let inputs = makeInputs(
            rects: [range: headword],
            ranges: [range],
            readings: [0: "ねこねこ"]  // wider than the kanji
        )
        let seg = KiokuDebugOverlayGeometry.segments(inputs).first!
        // Envelope is the union of the standardized headword + furigana rects.
        XCTAssertEqual(seg.envelopeRect, seg.headwordRect.union(seg.furiganaRect!),
            "Envelope must be exactly the rect union — selection / hit testing reuses this.")
        XCTAssertLessThan(seg.envelopeRect.minY, headword.minY,
            "When ruby is wider, envelope extends upward to include it.")
    }

    func test_envelope_equalsHeadword_whenNoRuby() {
        let range = NSRange(location: 0, length: 1)
        let headword = CGRect(x: 50, y: 200, width: 24, height: 24)
        let inputs = makeInputs(
            rects: [range: headword],
            ranges: [range]
        )
        let seg = KiokuDebugOverlayGeometry.segments(inputs).first!
        XCTAssertEqual(seg.envelopeRect, seg.headwordRect,
            "With no ruby, envelope is just the standardized headword rect.")
    }

    // MARK: - Missing rect handling

    func test_segmentWithoutCachedRect_isDropped() {
        // Two segments, only one has a rect cached. The other should be filtered out
        // rather than producing a (0,0,0,0) geometry that would draw at the origin.
        let r1 = NSRange(location: 0, length: 1)
        let r2 = NSRange(location: 1, length: 1)
        let inputs = makeInputs(
            rects: [r1: CGRect(x: 0, y: 0, width: 24, height: 24)],
            ranges: [r1, r2]
        )
        let segments = KiokuDebugOverlayGeometry.segments(inputs)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].location, 0)
    }

    // MARK: - Line bands

    func test_lineGeometry_splitsBandsCorrectly() {
        let frame = CGRect(x: 0, y: 100, width: 300, height: 30)
        let inputs = makeInputs(rects: [:], ranges: [], lines: [frame], bandHeight: 10)
        let lines = KiokuDebugOverlayGeometry.lines(inputs)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].furiganaBandRect, CGRect(x: 0, y: 100, width: 300, height: 10))
        XCTAssertEqual(lines[0].headwordBandRect, CGRect(x: 0, y: 110, width: 300, height: 20))
    }
}

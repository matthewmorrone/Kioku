import XCTest
import UIKit
@testable import Kioku

// Guards the wide-ruby line-start inset replacement. TextKit 2 used exclusion paths and
// suffered relayout cascades; the CoreText path shifts line origins directly. This test
// suite locks the input → shift contract so future refactors don't silently lose the
// inset (which would clip ruby at the left edge of any line whose first segment is wide).
final class KiokuWideRubyLineInsetTests: XCTestCase {

    private let baseFont = UIFont.systemFont(ofSize: 18)
    private let furiFont = UIFont.systemFont(ofSize: 9)

    func test_noSegments_returnsEmpty() {
        let shifts = KiokuWideRubyLineInset.shifts(
            for: .init(
                lineStringStarts: [0],
                segmentNSRanges: [],
                readingByLocation: [:],
                baseFont: baseFont,
                furiganaFont: furiFont,
                kanjiWidthOverrides: [:]
            ),
            sourceText: "猫"
        )
        XCTAssertEqual(shifts, [:])
    }

    func test_noFurigana_returnsEmpty() {
        let shifts = KiokuWideRubyLineInset.shifts(
            for: .init(
                lineStringStarts: [0],
                segmentNSRanges: [NSRange(location: 0, length: 1)],
                readingByLocation: [:],
                baseFont: baseFont,
                furiganaFont: furiFont,
                kanjiWidthOverrides: [:]
            ),
            sourceText: "猫"
        )
        XCTAssertEqual(shifts, [:])
    }

    func test_narrowRuby_producesNoShift() {
        // "猫" (one kanji) with ruby "ね" (one kana, half-width relative to kanji): ruby
        // never overhangs.
        let shifts = KiokuWideRubyLineInset.shifts(
            for: .init(
                lineStringStarts: [0],
                segmentNSRanges: [NSRange(location: 0, length: 1)],
                readingByLocation: [0: "ね"],
                baseFont: baseFont,
                furiganaFont: furiFont,
                kanjiWidthOverrides: [:]
            ),
            sourceText: "猫"
        )
        XCTAssertEqual(shifts, [:])
    }

    func test_wideRubyOnLineStart_producesPositiveShift() {
        // Single-kanji segment whose ruby spans 6 characters — definitely wider than 1
        // kanji width at any reasonable font size.
        let shifts = KiokuWideRubyLineInset.shifts(
            for: .init(
                lineStringStarts: [0],
                segmentNSRanges: [NSRange(location: 0, length: 1)],
                readingByLocation: [0: "あいうえおか"],
                baseFont: baseFont,
                furiganaFont: furiFont,
                kanjiWidthOverrides: [:]
            ),
            sourceText: "為"
        )
        XCTAssertNotNil(shifts[0])
        XCTAssertGreaterThan(shifts[0] ?? 0, 0)
    }

    func test_wideRubyOnMidLineSegment_noShift() {
        // Two segments — wide ruby on the SECOND one. Only the first segment of a line
        // can produce an overhang (others' rubies are inside the laid-out width).
        let shifts = KiokuWideRubyLineInset.shifts(
            for: .init(
                lineStringStarts: [0],
                segmentNSRanges: [
                    NSRange(location: 0, length: 2),  // first segment on the line
                    NSRange(location: 2, length: 1),  // second segment, has wide ruby
                ],
                readingByLocation: [2: "あいうえおか"],
                baseFont: baseFont,
                furiganaFont: furiFont,
                kanjiWidthOverrides: [:]
            ),
            sourceText: "あい為"
        )
        XCTAssertEqual(shifts, [:],
            "Mid-line segments cannot cause line-start overhang; their ruby is bounded by\nlaid-out width.")
    }

    func test_shiftIsCeiledForCrispPixels() {
        let shifts = KiokuWideRubyLineInset.shifts(
            for: .init(
                lineStringStarts: [0],
                segmentNSRanges: [NSRange(location: 0, length: 1)],
                readingByLocation: [0: "あいうえおか"],
                baseFont: baseFont,
                furiganaFont: furiFont,
                kanjiWidthOverrides: [:]
            ),
            sourceText: "為"
        )
        let value = shifts[0]!
        XCTAssertEqual(value, value.rounded(.up),
            "Shift must be ceil-ed so pixel rounding doesn't cause sub-pixel clipping.")
    }
}

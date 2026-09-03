import XCTest
@testable import Kioku

// Reproduction for: a Breakdown headword like 力 (ちから) drew its furigana clipped on both
// sides. Root cause: FuriganaView.naturalSize() measured furigana width from the `reading`
// field, but callers using per-run furigana (FuriganaLabel, e.g. SongLineCard's word-list
// headwords) pass `reading: ""` and carry the actual text in `explicitRunReadings` instead --
// so a wide reading over a narrow kanji (ちから over 力) measured as zero width, under-reporting
// the box the view needed. SwiftUI then allocated a frame only as wide as 力 itself, and
// draw(_:) centered the wider ちから partly outside `bounds`, where UIKit content is silently
// discarded -- the same class of clipping FuriganaViewTests' sibling fix
// (measuredLineHeight) addressed vertically.
@MainActor
final class FuriganaViewTests: XCTestCase {
    private func furiganaWidth(of text: String, baseFontSize: CGFloat) -> CGFloat {
        let furiganaFont = UIFont.systemFont(ofSize: baseFontSize * TypographySettings.furiganaSizeFactor)
        return (text as NSString).size(withAttributes: [.font: furiganaFont]).width
    }

    func testNaturalSizeAccountsForWiderExplicitRunReading() {
        let view = FuriganaView()
        let font = UIFont.systemFont(ofSize: 28, weight: .medium)
        view.configure(surface: "力", reading: "", font: font, gap: 2, explicitRunReadings: [0: "ちから"])

        let size = view.naturalSize()
        let expectedMinWidth = furiganaWidth(of: "ちから", baseFontSize: font.pointSize)
        XCTAssertGreaterThanOrEqual(
            size.width, expectedMinWidth,
            "natural width (\(size.width)) must be at least as wide as the furigana it draws (\(expectedMinWidth)), or the wider reading clips against bounds"
        )
    }

    // The widest of several explicit-run readings governs, not just the first or the sum.
    func testNaturalSizeUsesTheWidestOfSeveralExplicitRuns() {
        let view = FuriganaView()
        let font = UIFont.systemFont(ofSize: 28, weight: .medium)
        // A narrow reading at run 0, a much wider one at run 1.
        view.configure(surface: "上下", reading: "", font: font, gap: 2, explicitRunReadings: [0: "うえ", 1: "しもじも"])

        let size = view.naturalSize()
        let widerExpected = furiganaWidth(of: "しもじも", baseFontSize: font.pointSize)
        XCTAssertGreaterThanOrEqual(size.width, widerExpected)
    }

    // The non-explicit-run call shape (a single `reading` string covering the whole surface) is
    // unchanged by this fix -- still measures width from `reading` directly.
    func testNaturalSizeStillUsesPlainReadingWhenNoExplicitRuns() {
        let view = FuriganaView()
        let font = UIFont.systemFont(ofSize: 28, weight: .medium)
        view.configure(surface: "力", reading: "ちから", font: font, gap: 2)

        let size = view.naturalSize()
        let expectedMinWidth = furiganaWidth(of: "ちから", baseFontSize: font.pointSize)
        XCTAssertGreaterThanOrEqual(size.width, expectedMinWidth)
    }
}

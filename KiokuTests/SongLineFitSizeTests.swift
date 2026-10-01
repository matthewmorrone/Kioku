import XCTest
@testable import Kioku

// Covers the font size a breakdown card's Japanese line shrinks to so it stays on one line.
@MainActor
final class SongLineFitSizeTests: XCTestCase {
    // The size the card's plain branch uses.
    private func fitted(_ text: String, width: CGFloat) -> CGFloat {
        SongLineFitSize.size(for: text, baseSize: 28, availableWidth: width, font: { UIFont.systemFont(ofSize: $0) })
    }

    // A line that already fits keeps the full size; unmeasured width (0) does too.
    func testShortLineKeepsFullSize() {
        XCTAssertEqual(fitted("後悔はしない", width: 1000), 28)
        XCTAssertEqual(fitted("どんなにつらい宿命でも追いつづけるから", width: 0), 28)
    }

    // A line slightly too wide shrinks just enough to fit.
    func testLongLineShrinksToFit() {
        let natural = ("どんなにつらい宿命でも" as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 28)]).width
        XCTAssertEqual(fitted("どんなにつらい宿命でも", width: natural * 0.8), 28 * 0.8 / SongLineFitSize.widthSafetyMargin, accuracy: 0.5)
    }

    // A line far too wide stops at the minimum scale and wraps from there.
    func testVeryLongLineStopsAtMinimumScale() {
        XCTAssertEqual(fitted("どんなにつらい宿命でも追いつづけるから", width: 50), 28 * SongLineFitSize.minimumScale)
    }

    // Furigana wider than its kanji counts toward the line's width.
    func testWideRubyWidensTheLine() {
        let text = "宿命"
        let plain = fitted(text, width: 60)
        let withRuby = SongLineFitSize.size(
            for: text, baseSize: 28, availableWidth: 60, font: { UIFont.systemFont(ofSize: $0) },
            segmentationRanges: [text.startIndex..<text.endIndex],
            furiganaBySegmentLocation: [0: "しゅくめいしゅくめい"]
        )
        XCTAssertLessThan(withRuby, plain)
    }
}

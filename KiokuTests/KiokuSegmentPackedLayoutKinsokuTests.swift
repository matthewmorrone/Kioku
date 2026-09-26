import XCTest
import UIKit
import CoreText
@testable import Kioku

// Locks in the packer's kinsoku rule: a segment starting with a line-start-prohibited mark
// (、。」 …) never opens a line — the segment before it wraps down with it instead.
@MainActor
final class KiokuSegmentPackedLayoutKinsokuTests: XCTestCase {

    private let bodyFont = UIFont.systemFont(ofSize: 20)
    private let furiganaFont = UIFont.systemFont(ofSize: 10)
    private let leftInset: CGFloat = 4

    // Packs `segments` (one string per segment, in order) into `availableWidth` and returns
    // the line index of every placement, so tests can assert where each segment landed.
    private func lineIndices(_ segments: [String], availableWidth: CGFloat) -> [Int] {
        let text = segments.joined()
        var ranges: [NSRange] = []
        var location = 0
        for segment in segments {
            let length = (segment as NSString).length
            ranges.append(NSRange(location: location, length: length))
            location += length
        }
        let result = KiokuSegmentPackedLayout.pack(.init(
            attributedString: NSAttributedString(string: text, attributes: [.font: bodyFont]),
            segmentNSRanges: ranges,
            furiganaByLocation: [:],
            furiganaLengthByLocation: [:],
            baseFont: bodyFont,
            furiganaFont: furiganaFont,
            availableWidth: availableWidth,
            topInset: 0,
            interLineGap: 0,
            leftInset: leftInset
        ))
        return result.placements.map(\.lineIndex)
    }

    // Measures one segment the way the packer does, so widths line up with its wrap decision.
    private func width(_ text: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: bodyFont]) as CFAttributedString
        )
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    // Three words fill the line exactly, so the 。 would open line 2; the third word goes down
    // with it and line 1 ends short.
    func testPeriodCarriesPrecedingSegmentToNextLine() {
        let segments = ["情報", "処理", "技術", "。"]
        let available = width("情報処理技術") + 1
        XCTAssertEqual(lineIndices(segments, availableWidth: available), [0, 0, 1, 1])
    }

    // A run of prohibited marks (」。) moves together with the word before them.
    func testRunOfClosingMarksMovesWithItsWord() {
        let segments = ["情報", "処理", "」", "。"]
        let available = width("情報処理」") + 1
        XCTAssertEqual(lineIndices(segments, availableWidth: available), [0, 1, 1, 1])
    }

    // A line holding only one word can't give it up without going empty, so the mark wraps
    // alone rather than leaving a blank line.
    func testSingleSegmentLineKeepsItsSegment() {
        let segments = ["情報処理", "。"]
        let available = width("情報処理") + 1
        XCTAssertEqual(lineIndices(segments, availableWidth: available), [0, 1])
    }

    // Ordinary wrapping is unchanged when the overflowing segment is not punctuation.
    func testNonPunctuationWrapsNormally() {
        let segments = ["情報", "処理", "技術"]
        let available = width("情報処理") + 1
        XCTAssertEqual(lineIndices(segments, availableWidth: available), [0, 0, 1])
    }
}

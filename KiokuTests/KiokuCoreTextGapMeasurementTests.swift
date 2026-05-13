import XCTest
import UIKit
import CoreText
@testable import Kioku

// Measures and asserts ACTUAL geometric gaps in the CoreText renderer pipeline so we
// can catch alignment regressions numerically — no eyeballing screenshots. Each test
// builds the attributed string with the same data ReadView passes in, lays it out
// through the engine, applies the left-bearing auto-shift, and then probes:
//
//   1. INSET → FIRST SEGMENT: distance from the line's leftInset (contentInset.left)
//      to the first non-empty segment's left glyph edge on that line. Negative means
//      the first segment overhangs the inset to the left, which would visually clip
//      ruby annotations against the content edge.
//
//   2. INTER-SEGMENT GAPS: distance between adjacent segment trailing/leading edges
//      on the same line. A near-zero value means segments are visually touching.
//      Positive values are the user-kerning + any ruby-overhang compensation we
//      injected via .kern on the segment boundary.
//
// Numbers print on failure (and via XCTContext when wanted) so we can compare against
// TK2 hand-measurements if we ever capture them.
final class KiokuCoreTextGapMeasurementTests: XCTestCase {

    private let logURL = URL(fileURLWithPath: "/tmp/kioku-gap-measurements.log")

    override class func setUp() {
        super.setUp()
        // Truncate once per test class, not per test, so all tests' output lands in one
        // file in deterministic order.
        try? "".write(to: URL(fileURLWithPath: "/tmp/kioku-gap-measurements.log"),
                      atomically: true, encoding: .utf8)
    }

    private func log(_ message: String) {
        let line = message + "\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        }
    }

    // Sample text mirrors the seeded note used for the visual A/B — same line count,
    // same kanji segments. Keep these in sync if the seed changes.
    private let text = "今日は猫が見える。\n明日は彼女と会える。\n涙の意味を知る星空。\n稲妻のように激しく愛を叫ぶ。\n為替の動向を確認する。\nたとえどんな暗闇でも一人じゃない。\n王子様に運命投げず自ら戦う意志。"

    // Hand-curated (kanji-location, length, reading) triples that match what the
    // segmenter + lexicon produce for the text above. Each entry is one ruby that
    // CTRubyAnnotation will render. These are NSRange UTF-16 offsets within `text`.
    private var rubyTriples: [(Int, Int, String)] {
        let ns = text as NSString
        func loc(_ s: String) -> Int { ns.range(of: s).location }
        return [
            (loc("今日"), 2, "こんにち"),
            (loc("猫"), 1, "ねこ"),
            (loc("見"), 1, "み"),
            (loc("明日"), 2, "あした"),
            (loc("彼女"), 2, "かのじょ"),
            (loc("会"), 1, "あ"),
            (loc("涙"), 1, "なみだ"),
            (loc("意味"), 2, "いみ"),
            (loc("知"), 1, "し"),
            (loc("星空"), 2, "ほしぞら"),
            (loc("稲妻"), 2, "いなずま"),
            (loc("激"), 1, "はげ"),
            (loc("愛"), 1, "あい"),
            (loc("叫"), 1, "さけ"),
            (loc("為替"), 2, "かわせ"),
            (loc("動向"), 2, "どうこう"),
            (loc("確認"), 2, "かくにん"),
            (loc("暗闇"), 2, "くらやみ"),
            (loc("一人"), 2, "ひとり"),
            (loc("王子様"), 3, "おうじさま"),
            (loc("運命"), 2, "うんめい"),
            (loc("自"), 1, "みずか"),
            (loc("戦"), 1, "たたか"),
            (loc("意志"), 2, "いし"),
        ]
    }

    private func makeBuilderInputs() -> KiokuCoreTextAttributedStringBuilder.Inputs {
        let triples = rubyTriples
        var readings: [Int: String] = [:]
        var lengths: [Int: Int] = [:]
        for (loc, len, reading) in triples {
            readings[loc] = reading
            lengths[loc] = len
        }
        // Realistic word-level segmentation hand-curated from the sample text. Each
        // segment is one "word" the segmenter would produce — kanji compounds, particles,
        // verb stems with okurigana, and trailing punctuation are each their own segment.
        // This makes segment→next-segment gap measurements meaningful.
        let segmentSurfaces: [String] = [
            // Line 1
            "今日", "は", "猫", "が", "見える", "。",
            // Line 2
            "明日", "は", "彼女", "と", "会える", "。",
            // Line 3
            "涙", "の", "意味", "を", "知る", "星空", "。",
            // Line 4
            "稲妻", "のように", "激しく", "愛", "を", "叫ぶ", "。",
            // Line 5
            "為替", "の", "動向", "を", "確認", "する", "。",
            // Line 6
            "たとえ", "どんな", "暗闇", "でも", "一人", "じゃない", "。",
            // Line 7
            "王子様", "に", "運命", "投げず", "自ら", "戦う", "意志", "。",
        ]
        var segments: [Range<String.Index>] = []
        var cursor = text.startIndex
        for surface in segmentSurfaces {
            if let found = text.range(of: surface, range: cursor..<text.endIndex) {
                segments.append(found)
                cursor = found.upperBound
            }
        }
        return .init(
            text: text,
            segmentationRanges: segments,
            furiganaBySegmentLocation: readings,
            furiganaLengthBySegmentLocation: lengths,
            textSize: 18,
            lineSpacing: 6,
            kerning: 1,
            isVisualEnhancementsEnabled: true,
            isColorAlternationEnabled: true,
            isFuriganaVisible: true,
            evenSegmentColor: .systemRed,
            oddSegmentColor: .systemBlue,
            unknownSegmentLocations: [],
            isHighlightUnknownEnabled: false,
            unknownSegmentColor: .label
        )
    }

    // MARK: - Inset → first segment gap

    // Measures, per line, the horizontal gap from the left inset guide (contentInset.left)
    // to the FIRST SEGMENT'S left edge on that line. Positive gap means the segment
    // starts to the right of the inset (expected); negative gap would mean the segment's
    // first glyph overhangs the inset (visible clipping risk).
    func test_insetToFirstSegmentGap_perLine() {
        let inputs = makeBuilderInputs()
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        let engine = KiokuTextLayoutEngine(
            attributedString: attributed,
            widthConstraint: 380,
            contentInset: UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        )
        let baseFont = UIFont.systemFont(ofSize: 18)
        let furiFont = UIFont.systemFont(ofSize: 9)
        let segmentNSRanges: [NSRange] = inputs.segmentationRanges
            .map { NSRange($0, in: inputs.text) }
            .filter { $0.location != NSNotFound && $0.length > 0 }
        var shifts = KiokuWideRubyLineInset.shifts(
            for: .init(
                lineStringStarts: engine.lines.map { $0.stringRange.location },
                segmentNSRanges: segmentNSRanges,
                readingByLocation: inputs.furiganaBySegmentLocation,
                baseFont: baseFont,
                furiganaFont: furiFont,
                kanjiWidthOverrides: [:]
            ),
            sourceText: inputs.text
        )
        for (index, line) in engine.lines.enumerated() {
            let bounds = CTLineGetImageBounds(line.line, nil)
            if bounds.minX < 0 {
                shifts[index] = max(shifts[index] ?? 0, ceil(-bounds.minX))
            }
        }
        engine.setLineOriginShifts(shifts)

        for (index, line) in engine.lines.enumerated() {
            // First segment on this line = segment whose location is at the line's start.
            // Use firstRect on the segment's NSRange to find the segment's left edge.
            guard let firstSegment = segmentNSRanges.first(where: { $0.location == line.stringRange.location }) else {
                log("[gap] line=\(index) noFirstSegment")
                continue
            }
            guard let segmentRect = engine.firstRect(forCharacterRange: firstSegment) else {
                log("[gap] line=\(index) noSegmentRect")
                continue
            }
            let inset = engine.contentInset.left
            let segmentLeft = segmentRect.minX
            let insetToFirstSegment = segmentLeft - inset
            log("[gap] line=\(index) inset=\(inset) firstSegmentLeft=\(segmentLeft) gap=\(insetToFirstSegment) appliedShift=\(shifts[index] ?? 0)")
            // Segment edges should sit AT or RIGHT OF the inset guide. A negative gap
            // would mean the segment box visibly overhangs the inset line.
            XCTAssertGreaterThanOrEqual(insetToFirstSegment, -0.5,
                "Line \(index)'s first segment must not extend left of the inset guide.")
        }
    }

    // MARK: - Inter-segment gaps

    // Measures, for each adjacent pair of segments on the SAME LINE, the gap from
    // segment-N's right edge to segment-N+1's left edge. Positive = visible space
    // between them; ≈ 0 = touching; negative = overlap.
    func test_segmentToNextSegmentGap_perPair() {
        let inputs = makeBuilderInputs()
        let attributed = KiokuCoreTextAttributedStringBuilder.build(inputs)
        let engine = KiokuTextLayoutEngine(
            attributedString: attributed,
            widthConstraint: 380,
            contentInset: UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        )
        let baseFont = UIFont.systemFont(ofSize: 18)
        let furiFont = UIFont.systemFont(ofSize: 9)
        let segmentNSRanges: [NSRange] = inputs.segmentationRanges
            .map { NSRange($0, in: inputs.text) }
            .filter { $0.location != NSNotFound && $0.length > 0 }
        var shifts = KiokuWideRubyLineInset.shifts(
            for: .init(
                lineStringStarts: engine.lines.map { $0.stringRange.location },
                segmentNSRanges: segmentNSRanges,
                readingByLocation: inputs.furiganaBySegmentLocation,
                baseFont: baseFont,
                furiganaFont: furiFont,
                kanjiWidthOverrides: [:]
            ),
            sourceText: inputs.text
        )
        for (index, line) in engine.lines.enumerated() {
            let bounds = CTLineGetImageBounds(line.line, nil)
            if bounds.minX < 0 {
                shifts[index] = max(shifts[index] ?? 0, ceil(-bounds.minX))
            }
        }
        engine.setLineOriginShifts(shifts)

        // Build a (segment, rect) list in document order, then pair adjacent entries.
        let segmentRects: [(NSRange, CGRect)] = segmentNSRanges.compactMap { range in
            guard let r = engine.firstRect(forCharacterRange: range) else { return nil }
            return (range, r)
        }
        var pairsChecked = 0
        for i in 0..<(segmentRects.count - 1) {
            let (rangeA, rectA) = segmentRects[i]
            let (rangeB, rectB) = segmentRects[i + 1]
            // Same-line check: vertical midpoints within a few points of each other.
            guard abs(rectA.midY - rectB.midY) < 5 else {
                log("[gap] pairSegments locA=\(rangeA.location) locB=\(rangeB.location) skip=differentLines")
                continue
            }
            // Use the engine's firstRect maxX directly — that's the segment's right
            // edge as the engine reports it, including any inter-segment kern we
            // injected for ruby spacing.
            let gap = rectB.minX - rectA.maxX
            log("[gap] pairSegments locA=\(rangeA.location) locB=\(rangeB.location) rightA=\(rectA.maxX) leftB=\(rectB.minX) gap=\(gap)")
            XCTAssertGreaterThan(gap, -1.0,
                "Adjacent segments on same line must not overlap; pair (\(rangeA.location), \(rangeB.location)) gap=\(gap).")
            pairsChecked += 1
        }
        XCTAssertGreaterThan(pairsChecked, 0, "Expected at least one same-line segment pair to probe.")
    }
}

import XCTest
import UIKit
import CoreText
@testable import Kioku

// Ruby wider than its kanji may reach over its own word's okurigana (戦う) by
// KiokuRubyPadding.okuriganaOverhangAllowance, and over the next word's kana (涙は) by
// KiokuRubyPadding.wordBoundaryOverhangAllowance, before space is added. These pin which value each
// spacing rule reads: the builder's okurigana kern, the builder's between-words kern, and the
// segment packer.
@MainActor
final class KiokuRubyOverhangAllowanceTests: XCTestCase {

    private let textSize: CGFloat = 18
    private var baseFont: UIFont { UIFont.systemFont(ofSize: textSize) }
    private var furiganaFont: UIFont { UIFont.systemFont(ofSize: textSize * TypographySettings.furiganaSizeFactor) }

    // The space an allowance leaves after a kanji run: its overhang on one side beyond the
    // allowance, rounded up the way the builder rounds it.
    private func expectedPadding(kanji: String, reading: String, allowance: CGFloat) -> CGFloat {
        let kanjiW = ceil((kanji as NSString).size(withAttributes: [.font: baseFont]).width)
        let rubyW = ceil((reading as NSString).size(withAttributes: [.font: furiganaFont]).width)
        return max(0, ceil((rubyW - kanjiW) / 2 - allowance))
    }

    private var okuriganaAllowance: CGFloat { KiokuRubyPadding.okuriganaOverhangAllowance(furiganaFont: furiganaFont) }
    private var wordBoundaryAllowance: CGFloat { KiokuRubyPadding.wordBoundaryOverhangAllowance(furiganaFont: furiganaFont) }

    // Builder output for `text` split into `segments`, with readings keyed by kanji-run location.
    private func build(
        _ text: String,
        segments: [String],
        furigana: [Int: String],
        furiganaLength: [Int: Int],
        isSegmentPacked: Bool
    ) -> NSAttributedString {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        for surface in segments {
            let end = text.index(start, offsetBy: surface.count)
            ranges.append(start..<end)
            start = end
        }
        var inputs = KiokuCoreTextAttributedStringBuilder.Inputs(
            text: text,
            segmentationRanges: ranges,
            furiganaBySegmentLocation: furigana,
            furiganaLengthBySegmentLocation: furiganaLength,
            textSize: textSize,
            lineSpacing: 4,
            kerning: 0,
            isVisualEnhancementsEnabled: true,
            isColorAlternationEnabled: true,
            isFuriganaVisible: true,
            evenSegmentColor: .systemRed,
            oddSegmentColor: .systemBlue
        )
        inputs.isSegmentPacked = isSegmentPacked
        return KiokuCoreTextAttributedStringBuilder.build(inputs).attributedString
    }

    private func kern(_ string: NSAttributedString, at index: Int) -> CGFloat {
        string.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat ?? 0
    }

    // Ruby may overhang its own okurigana by half a ruby character, the next word's kana not at all.
    func test_allowances() {
        XCTAssertEqual(okuriganaAllowance, furiganaFont.pointSize / 2)
        XCTAssertEqual(wordBoundaryAllowance, 0)
    }

    // Okurigana: 戦う with たたか — the kern after 戦 is its overhang beyond the allowance.
    func test_okurigana_kernIsOverhangBeyondAllowance() {
        let attributed = build("戦う", segments: ["戦う"], furigana: [0: "たたか"], furiganaLength: [0: 1], isSegmentPacked: true)
        XCTAssertEqual(kern(attributed, at: 0), expectedPadding(kanji: "戦", reading: "たたか", allowance: okuriganaAllowance), accuracy: 0.01)
    }

    // A reading long enough to exceed the allowance still pushes its okurigana away: 憤り with いきどお.
    func test_okurigana_longReadingStillAddsSpace() {
        let attributed = build("憤り", segments: ["憤り"], furigana: [0: "いきどお"], furiganaLength: [0: 1], isSegmentPacked: true)
        let padding = expectedPadding(kanji: "憤", reading: "いきどお", allowance: okuriganaAllowance)
        XCTAssertGreaterThan(padding, 0)
        XCTAssertEqual(kern(attributed, at: 0), padding, accuracy: 0.01)
    }

    // Between words, unpacked: 涙|は — the kern after 涙 uses the word-boundary allowance.
    func test_betweenWords_unpacked_kernIsOverhangBeyondAllowance() {
        let attributed = build("涙は", segments: ["涙", "は"], furigana: [0: "なみだ"], furiganaLength: [0: 1], isSegmentPacked: false)
        XCTAssertEqual(kern(attributed, at: 0), expectedPadding(kanji: "涙", reading: "なみだ", allowance: wordBoundaryAllowance), accuracy: 0.01)
    }

    // Between words, unpacked, next to another reading: 涙|瞳 — no allowance, or the two readings
    // would collide. Both overhang into the same gap, so the kern after 涙 is なみだ's full right
    // overhang plus ひとみ's full left overhang.
    func test_betweenWords_unpacked_neighbourUnderRubyGetsFullOverhang() {
        let attributed = build("涙瞳", segments: ["涙", "瞳"], furigana: [0: "なみだ", 1: "ひとみ"], furiganaLength: [0: 1, 1: 1], isSegmentPacked: false)
        let fullOverhang: (String, String) -> CGFloat = { kanji, reading in
            let kanjiW = ceil((kanji as NSString).size(withAttributes: [.font: self.baseFont]).width)
            let rubyW = ceil((reading as NSString).size(withAttributes: [.font: self.furiganaFont]).width)
            return max(0, ceil((rubyW - kanjiW) / 2))
        }
        XCTAssertEqual(kern(attributed, at: 0), fullOverhang("涙", "なみだ") + fullOverhang("瞳", "ひとみ"), accuracy: 0.01)
    }

    // Packs two one-character segments with the given readings and returns both placements.
    private func pack(_ text: String, furigana: [Int: String]) -> [KiokuSegmentPackedLayout.Placement] {
        let attributed = build(text, segments: text.map(String.init), furigana: furigana, furiganaLength: furigana.mapValues { _ in 1 }, isSegmentPacked: true)
        return KiokuSegmentPackedLayout.pack(.init(
            attributedString: attributed,
            segmentNSRanges: [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)],
            furiganaByLocation: furigana,
            furiganaLengthByLocation: furigana.mapValues { _ in 1 },
            baseFont: baseFont,
            furiganaFont: furiganaFont,
            availableWidth: 400,
            topInset: 0,
            interLineGap: 0,
            leftInset: 0
        )).placements
    }

    // Packed, 涙|は: は starts right after なみだ's right overhang; the ruby doesn't reach over it.
    func test_packed_nextKanaClearsRightOverhang() {
        let placements = pack("涙は", furigana: [0: "なみだ"])
        XCTAssertEqual(placements.count, 2)
        let tear = placements[0]
        XCTAssertGreaterThan(tear.rightOverhang, 0)
        XCTAssertEqual(placements[1].originX, tear.originX + tear.footprintWidth, accuracy: 0.01)
    }

    // Packed, 涙|瞳: both under ruby, so the second segment starts right after the first's footprint.
    func test_packed_neighbourUnderRubyDoesNotPullBack() {
        let placements = pack("涙瞳", furigana: [0: "なみだ", 1: "ひとみ"])
        XCTAssertEqual(placements.count, 2)
        XCTAssertEqual(placements[1].originX, placements[0].originX + placements[0].footprintWidth, accuracy: 0.01)
    }

    // Packed, は|涙: 涙's ruby doesn't reach back over は; its footprint starts after は.
    func test_packed_previousKanaClearsLeftOverhang() {
        let placements = pack("は涙", furigana: [1: "なみだ"])
        XCTAssertEqual(placements.count, 2)
        let tear = placements[1]
        XCTAssertGreaterThan(tear.leftOverhang, 0)
        XCTAssertEqual(tear.originX, placements[0].originX + placements[0].footprintWidth, accuracy: 0.01)
    }
}

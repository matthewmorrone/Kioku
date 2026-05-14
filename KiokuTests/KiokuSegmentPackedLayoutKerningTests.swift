import XCTest
import UIKit
import CoreText
@testable import Kioku

// Locks in the left-inset invariant under varying `.kern` values.
//
// Spec the packer must respect: for a first-on-line segment with wide ruby, the
// envelope (= max of headword's CTLine width and ruby's NSString.size width,
// adjusted for where each ruby-run sits inside the segment) sits flush at the left
// inset. Adding `.kern` to the base attributes shifts kanji-run positions within
// the segment's CTLine — if the packer's overhang computation doesn't reflect
// kerning, the rendered ruby's left edge drifts past the inset.
//
// These tests sweep kerning from 0pt to 12pt (the user's slider range) on a
// first-segment-on-line scenario where the ruby is wider than its kanji, and assert
// that the envelope's left edge always sits at the inset and the kanji-run-centered
// ruby never extends left of placement.originX.
final class KiokuSegmentPackedLayoutKerningTests: XCTestCase {

    private let bodyFont = UIFont.systemFont(ofSize: 18)
    private let furiganaFont = UIFont.systemFont(ofSize: 9)
    private let leftInset: CGFloat = 4
    private let availableWidth: CGFloat = 400
    private let topInset: CGFloat = 10
    private let interLineGap: CGFloat = 2

    // Builds an attributed string with `.kern` applied uniformly, matching what the
    // builder produces for live renders.
    private func makeAttributed(_ text: String, kerning: CGFloat) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [.font: bodyFont, .kern: kerning]
        )
    }

    // Runs the packer for a single-segment input with one wide ruby and returns the
    // sole placement. Test scenarios share this scaffolding so we can sweep `kerning`
    // without duplicating setup.
    private func packSingleSegmentWithWideRuby(
        text: String,
        rubyReading: String,
        kanjiLocation: Int,
        kanjiLength: Int,
        kerning: CGFloat
    ) -> KiokuSegmentPackedLayout.Placement {
        let attributed = makeAttributed(text, kerning: kerning)
        let nsText = text as NSString
        let segRange = NSRange(location: 0, length: nsText.length)
        let result = KiokuSegmentPackedLayout.pack(.init(
            attributedString: attributed,
            segmentNSRanges: [segRange],
            furiganaByLocation: [kanjiLocation: rubyReading],
            furiganaLengthByLocation: [kanjiLocation: kanjiLength],
            baseFont: bodyFont,
            furiganaFont: furiganaFont,
            availableWidth: availableWidth,
            topInset: topInset,
            interLineGap: interLineGap,
            leftInset: leftInset
        ))
        return result.placements.first!
    }

    // Computes where the ruby's left edge will actually render given the placement.
    // Matches the renderer's `drawSegmentPacked` math exactly:
    //   headwordOriginX = placement.originX + placement.leftOverhang
    //   kanjiCenter     = headwordOriginX + (CT offset at kanjiLoc + CT offset at kanjiEnd) / 2
    //   rubyLeft        = kanjiCenter - rubyWidth / 2
    private func renderedRubyLeftEdge(
        text: String,
        rubyReading: String,
        kanjiLocation: Int,
        kanjiLength: Int,
        kerning: CGFloat,
        placement: KiokuSegmentPackedLayout.Placement
    ) -> CGFloat {
        let attributed = makeAttributed(text, kerning: kerning)
        let segLine = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let xStart = CGFloat(CTLineGetOffsetForStringIndex(segLine, kanjiLocation, nil))
        let xEnd = CGFloat(CTLineGetOffsetForStringIndex(segLine, kanjiLocation + kanjiLength, nil))
        let kanjiMidInHeadword = (xStart + xEnd) / 2
        let headwordOriginX = placement.originX + placement.leftOverhang
        let kanjiMidX = headwordOriginX + kanjiMidInHeadword
        let rubyLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: rubyReading, attributes: [.font: furiganaFont]) as CFAttributedString
        )
        let rubyWidth = CGFloat(CTLineGetTypographicBounds(rubyLine, nil, nil, nil))
        return kanjiMidX - rubyWidth / 2
    }

    // The headline invariant: for a wide-ruby segment first on its line, the rendered
    // ruby's left edge sits at the inset (within 1pt slop) for every kerning value the
    // user can set. If the packer doesn't account for kerning, the ruby drifts left
    // past the inset as kerning grows — and these assertions fail loudly.
    func test_firstSegmentWideRuby_rubyLeftAtInset_acrossKerning() {
        // 美しい with ruby うつく on 美 — wide ruby (3-char hiragana over 1 kanji).
        // The kanji-run sits at the LEFT of the segment, so ruby overhangs the segment's
        // left edge by (rubyWidth − kanjiWidth)/2. The packer's leftOverhang must absorb
        // that overhang into the footprint and shift the headword right by the same
        // amount so the rendered ruby snaps to the inset.
        let text = "美しい"
        let ruby = "うつく"
        let kerningValues: [CGFloat] = [0, 1, 2, 4, 8, 12]
        for kerning in kerningValues {
            let placement = packSingleSegmentWithWideRuby(
                text: text,
                rubyReading: ruby,
                kanjiLocation: 0,
                kanjiLength: 1,
                kerning: kerning
            )
            XCTAssertEqual(placement.originX, leftInset, accuracy: 0.01,
                "kerning=\(kerning): footprint origin must equal inset for the first segment on a line")
            let rubyLeft = renderedRubyLeftEdge(
                text: text,
                rubyReading: ruby,
                kanjiLocation: 0,
                kanjiLength: 1,
                kerning: kerning,
                placement: placement
            )
            XCTAssertGreaterThanOrEqual(rubyLeft, leftInset - 1.0,
                "kerning=\(kerning): rendered ruby left (\(rubyLeft)) must not extend past inset (\(leftInset))")
            // Also assert the ruby doesn't crowd the kanji on the right when the packer
            // over-corrects — left edge should be within ~1pt of the inset, not centered
            // somewhere arbitrary.
            XCTAssertLessThanOrEqual(rubyLeft, leftInset + 1.5,
                "kerning=\(kerning): rendered ruby left (\(rubyLeft)) must be approximately AT the inset, not shifted further right")
        }
    }

    // Sanity for the no-overhang case: a segment whose ruby is NARROWER than its
    // kanji has no leftOverhang regardless of kerning, so the headword sits flush at
    // the inset. Adding kerning must not invent overhang where there is none.
    func test_firstSegmentNarrowRuby_headwordAtInset_acrossKerning() {
        // 朽ちた with ruby く on 朽ち... actually let's pick a case where ruby (1 hiragana)
        // is clearly narrower than kanji+okurigana (3 chars). The single-char ruby く
        // over the single-char 朽 is comparable to the kanji width — narrow ruby case.
        let text = "朽ちた"
        let ruby = "く"
        let kerningValues: [CGFloat] = [0, 1, 4, 12]
        for kerning in kerningValues {
            let placement = packSingleSegmentWithWideRuby(
                text: text,
                rubyReading: ruby,
                kanjiLocation: 0,
                kanjiLength: 1,
                kerning: kerning
            )
            XCTAssertEqual(placement.leftOverhang, 0, accuracy: 0.01,
                "kerning=\(kerning): narrow ruby must not produce left overhang")
            XCTAssertEqual(placement.originX, leftInset, accuracy: 0.01,
                "kerning=\(kerning): narrow-ruby first segment must place footprint at inset")
        }
    }

    // Per-character `.kern` is additive across characters in CTLine's typographic
    // bounds, so the headword width grows with kerning. This test pins that growth:
    // headwordWidth must increase by approximately (charCount × kerning) compared to
    // the kerning=0 baseline. Catches regressions where the packer measures with
    // NSString.size (no kern) and underestimates the footprint.
    func test_headwordWidth_scalesWithKerning() {
        let text = "情報処理"
        let baseline = packSingleSegmentWithWideRuby(
            text: text,
            rubyReading: "じょうほうしょり",
            kanjiLocation: 0,
            kanjiLength: 4,
            kerning: 0
        )
        let bumped = packSingleSegmentWithWideRuby(
            text: text,
            rubyReading: "じょうほうしょり",
            kanjiLocation: 0,
            kanjiLength: 4,
            kerning: 5
        )
        let expectedDelta: CGFloat = 5 * CGFloat(text.count - 1)  // kerning gaps BETWEEN chars
        let actualDelta = bumped.headwordWidth - baseline.headwordWidth
        XCTAssertEqual(actualDelta, expectedDelta, accuracy: 6.0,
            "headwordWidth must reflect kerning-driven inter-character advance growth (got Δ=\(actualDelta), expected ≈\(expectedDelta))")
    }
}

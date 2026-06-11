import UIKit

// Geometry helper for the read-mode selected-segment highlight rect, isolated from
// FuriganaTextRenderer so the envelope math (headword vs ruby width, vertical extent
// covering the furigana row) is testable without spinning up a UITextView.
//
// The formula here is deliberately pure: it receives the TextKit-derived `selectedRect`
// (which already encodes layout, line spacing, and container insets) and overlays the
// envelope/furigana computation that scales with text size. Anything beyond this helper
// — locating the selected segment, forcing layout, container conversion — stays in the
// renderer per AGENTS.md §9's single coordinate-pipeline contract.
enum FuriganaSelectedSegmentGeometry {
    // Computes the highlight rect that hugs the selected segment.
    //
    // Width  = max(headwordWidth, rubyWidth) + 2  (1pt inset on each side).
    // Height = selectedRect.height + furiganaRowHeight  (room for the ruby above).
    //
    // When `furigana` is supplied and wider than the headword, the rect expands sideways
    // around the headword's visual midpoint to match the ruby's centered placement.
    static func envelopeRect(
        selectedRect: CGRect,
        surface: String,
        furigana: String?,
        textSize: CGFloat,
        furiganaGap: CGFloat,
        kerning: CGFloat = 0
    ) -> CGRect {
        let baseFont = UIFont.systemFont(ofSize: textSize)
        let furiganaFont = UIFont.systemFont(ofSize: textSize * TypographySettings.furiganaSizeFactor)
        let visualHeadwordWidth = measureWidth(surface, font: baseFont, kerning: kerning)
        var envelopeMinX = selectedRect.minX
        var envelopeMaxX = selectedRect.minX + visualHeadwordWidth

        if let furigana, furigana.isEmpty == false {
            let furiganaWidth = measureWidth(furigana, font: furiganaFont, kerning: 0)
            let kanjiVisualMidX = selectedRect.minX + visualHeadwordWidth / 2
            envelopeMinX = min(envelopeMinX, kanjiVisualMidX - furiganaWidth / 2)
            envelopeMaxX = max(envelopeMaxX, kanjiVisualMidX + furiganaWidth / 2)
        }

        let furiganaRowHeight = furiganaFont.lineHeight + furiganaGap
        return CGRect(
            x: envelopeMinX - 1,
            y: selectedRect.minY - furiganaRowHeight,
            width: (envelopeMaxX - envelopeMinX) + 2,
            height: selectedRect.height + furiganaRowHeight
        )
    }

    // Mirrors the ceil-rounded width measurement used by the renderer so test expectations
    // can produce matching values without re-implementing the rounding rule.
    static func measureWidth(_ value: String, font: UIFont, kerning: CGFloat) -> CGFloat {
        guard value.isEmpty == false else { return 0 }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: kerning]
        return ceil((value as NSString).size(withAttributes: attributes).width)
    }
}

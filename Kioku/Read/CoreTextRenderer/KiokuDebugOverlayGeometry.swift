import UIKit

// Pure-value computation of the per-segment rects + per-line rects needed by the
// CoreText Read-mode debug overlay. Extracted from the view so all coordinate math
// is unit-testable without a UIView host.
//
// Coordinate convention: every output rect / X is in the layout engine's UIKit
// (top-down) coordinate space — same space `KiokuTextLayoutEngine.firstRect(...)`
// returns. The overlay view sits as a sibling at the same content origin, so no
// further conversion is needed at draw time.
enum KiokuDebugOverlayGeometry {

    // One segment's debug geometry. The headword rect comes from CoreText directly
    // (via `firstRect`), so its midX is the actual rendered center of the kanji —
    // bisectors using this midX cannot drift relative to the glyphs.
    struct SegmentGeometry: Equatable {
        let location: Int
        // Headword rect: tightly the KANJI-RUN inside this segment (not the full
        // segment surface). For "見える" with ruby on 見, this covers 見 only. For
        // single-kanji or all-kanji segments (like "為替"), it equals the full
        // segment rect. Bisectors anchor here so the vertical line passes through
        // the actual kanji glyph, not through any trailing okurigana.
        let headwordRect: CGRect
        // Ruby annotation rect centered above the headword.
        let furiganaRect: CGRect?
        // Envelope: full segment rect ∪ furigana rect — the selection / hit-test
        // shape, vertically expanded to include the ruby row.
        let envelopeRect: CGRect
        // Horizontal centerline of the headword (= ruby midX by CTRubyAnnotation
        // `.center` invariant). Bisectors use this.
        let bisectorX: CGFloat
    }

    // A laid-out line's frame plus the Y span reserved for ruby annotations above
    // it. The furigana band sits in the top `furiganaBandHeight` points; the
    // headword band fills the remainder.
    struct LineGeometry: Equatable {
        let frame: CGRect
        let furiganaBandHeight: CGFloat
        // Headword band: the lower portion of the line where base glyphs render.
        var headwordBandRect: CGRect {
            CGRect(
                x: frame.minX,
                y: frame.minY + furiganaBandHeight,
                width: frame.width,
                height: frame.height - furiganaBandHeight
            )
        }
        // Furigana band: the top portion reserved for ruby.
        var furiganaBandRect: CGRect {
            CGRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width,
                height: furiganaBandHeight
            )
        }
    }

    struct Inputs {
        // First-line rect for each segment by NSRange (segment-level — used for envelope).
        let firstRectByNSRange: [NSRange: CGRect]
        // UTF-16 NSRange for each segment in document order. Caller is responsible for
        // filtering out non-lexical segments (whitespace, newlines, punctuation-only) so
        // the overlay doesn't draw zero-content envelopes at line ends.
        let segmentNSRanges: [NSRange]
        // First-line rect for each KANJI-RUN inside a segment, keyed by run location.
        // Drives headword rect and bisector positioning so they hug the kanji glyphs
        // rather than spanning across okurigana.
        let kanjiRunRectByLocation: [Int: CGRect]
        let kanjiRunLengthByLocation: [Int: Int]
        // Reading text per kanji-run location.
        let readingByLocation: [Int: String]
        let baseFont: UIFont
        let furiganaFont: UIFont
        let lineFrames: [CGRect]
        let furiganaBandHeight: CGFloat
        // Whether to reserve a ruby row above each segment in its envelope. False means
        // furigana is currently hidden (or globally disabled), so the envelope should
        // collapse to just the headword height — otherwise toggling furigana off leaves
        // visually misleading "empty ruby band" space at the top of every envelope.
        var isFuriganaVisible: Bool = true
    }

    // Builds the segment-level debug geometry. Headword rect targets the kanji-run
    // inside the segment (when one exists) so bisectors pass through the actual kanji
    // glyphs — for "見える" with ruby み on 見, the headword is just 見, not the whole
    // word. The envelope spans the full segment ∪ ruby, since selection / hit-testing
    // reuses it.
    //
    // Heights are standardized to font lineHeight so all rects on a line look uniform.
    static func segments(_ inputs: Inputs) -> [SegmentGeometry] {
        let headwordHeight = ceil(inputs.baseFont.lineHeight)
        // Reserve a ruby row only when furigana is visible. Otherwise the envelope
        // collapses to headword height — toggling furigana OFF visually shrinks every
        // envelope, instead of leaving an empty ruby band that no longer matches reality.
        let rubyHeight = inputs.isFuriganaVisible ? ceil(inputs.furiganaFont.lineHeight) : 0
        return inputs.segmentNSRanges.compactMap { segRange -> SegmentGeometry? in
            guard let segRect = inputs.firstRectByNSRange[segRange] else { return nil }
            // Find a kanji-run contained inside this segment (first match wins; segments
            // with multiple ruby runs would need a richer model — out of scope for the
            // overlay).
            let kanjiRunEntry: (loc: Int, rect: CGRect, len: Int, reading: String)? = {
                for (kanjiLoc, kanjiRect) in inputs.kanjiRunRectByLocation {
                    guard NSLocationInRange(kanjiLoc, segRange) else { continue }
                    guard let kLen = inputs.kanjiRunLengthByLocation[kanjiLoc],
                          let reading = inputs.readingByLocation[kanjiLoc],
                          reading.isEmpty == false else { continue }
                    return (kanjiLoc, kanjiRect, kLen, reading)
                }
                return nil
            }()

            // Build the headword rect. When a kanji-run exists, use its rect (tight
            // around the kanji glyphs); otherwise fall back to the segment rect.
            let baseRectForHeadword = kanjiRunEntry?.rect ?? segRect
            let headwordRect = CGRect(
                x: baseRectForHeadword.origin.x,
                y: baseRectForHeadword.maxY - headwordHeight,
                width: baseRectForHeadword.width,
                height: headwordHeight
            )
            let bisectorX = headwordRect.midX

            // Build the furigana rect (centered above the kanji-run, NOT above the
            // segment — okurigana to the right of the kanji shouldn't shift the ruby).
            // Skipped entirely when furigana is hidden: there's no ruby being drawn, so
            // the debug rect would be a phantom marker for content that isn't on screen.
            let furiganaRect: CGRect?
            if inputs.isFuriganaVisible, let entry = kanjiRunEntry {
                let rubyWidth = ceil((entry.reading as NSString).size(withAttributes: [.font: inputs.furiganaFont]).width)
                furiganaRect = CGRect(
                    x: bisectorX - rubyWidth / 2,
                    y: headwordRect.minY - rubyHeight,
                    width: rubyWidth,
                    height: rubyHeight
                )
            } else {
                furiganaRect = nil
            }

            // Envelope = horizontal bounding box of (segment ∪ furigana) × (headword height
            // + ruby band when ruby exists). When ruby is wider than its kanji (ものがたり
            // over 物語), it overhangs the segment on both sides; the envelope grows to
            // contain it. When no ruby is present (no reading attached to this segment),
            // the ruby band collapses to zero — reserving it would draw a phantom strip
            // above the glyphs that doesn't reflect anything actually rendered, and would
            // make hit-testing register interactions in empty space.
            let envelopeMinX: CGFloat
            let envelopeMaxX: CGFloat
            if let furigana = furiganaRect {
                envelopeMinX = min(segRect.minX, furigana.minX)
                envelopeMaxX = max(segRect.maxX, furigana.maxX)
            } else {
                envelopeMinX = segRect.minX
                envelopeMaxX = segRect.maxX
            }
            let effectiveRubyHeight = furiganaRect == nil ? 0 : rubyHeight
            let envelope = CGRect(
                x: envelopeMinX,
                y: segRect.maxY - headwordHeight - effectiveRubyHeight,
                width: envelopeMaxX - envelopeMinX,
                height: headwordHeight + effectiveRubyHeight
            )

            return SegmentGeometry(
                location: segRange.location,
                headwordRect: headwordRect,
                furiganaRect: furiganaRect,
                envelopeRect: envelope,
                bisectorX: bisectorX
            )
        }
    }

    // Builds the per-line geometry used by the line-band debug toggles.
    static func lines(_ inputs: Inputs) -> [LineGeometry] {
        inputs.lineFrames.map {
            LineGeometry(frame: $0, furiganaBandHeight: inputs.furiganaBandHeight)
        }
    }
}

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
        // UTF-16 NSRange for each segment in document order.
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
        let rubyHeight = ceil(inputs.furiganaFont.lineHeight)
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
            let furiganaRect: CGRect?
            if let entry = kanjiRunEntry {
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

            // Envelope = segment width × (ruby height + headword height), anchored so the
            // headword baseline matches segRect.maxY. Heights are constant across all
            // segments on a line — segments without ruby get the same total height as
            // segments with ruby — so the overlay looks visually uniform.
            let envelope = CGRect(
                x: segRect.origin.x,
                y: segRect.maxY - headwordHeight - rubyHeight,
                width: segRect.width,
                height: headwordHeight + rubyHeight
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

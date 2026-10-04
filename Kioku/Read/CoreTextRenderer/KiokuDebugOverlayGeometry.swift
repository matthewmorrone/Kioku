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

    // A laid-out line's frame plus the ruby row drawn above it. The engine's line frame is
    // the headword row alone — ruby room is reserved in the gap ABOVE the frame, and the
    // renderer draws each reading with its bottom `furiganaGap` points above the frame's top
    // (KiokuCoreTextView.drawSegmentPacked / drawRuby). The bands mirror exactly that.
    struct LineGeometry: Equatable {
        let frame: CGRect
        let furiganaBandHeight: CGFloat
        let furiganaGap: CGFloat
        // Headword band: the line frame, where base glyphs render.
        var headwordBandRect: CGRect { frame }
        // Furigana band: the ruby row, ending `furiganaGap` above the headword row.
        var furiganaBandRect: CGRect {
            CGRect(
                x: frame.minX,
                y: frame.minY - furiganaGap - furiganaBandHeight,
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
        // Distance between the bottom of the ruby row and the top of the headword row.
        var furiganaGap: CGFloat = 0
        // Whether to reserve a ruby row above each segment in its envelope. False means
        // furigana is currently hidden (or globally disabled), so the envelope should
        // collapse to just the headword height — otherwise toggling furigana off leaves
        // visually misleading "empty ruby band" space at the top of every envelope.
        var isFuriganaVisible: Bool = true
    }

    // Builds the debug geometry: one entry per kanji run (one for a segment without any), so
    // bisectors pass through the actual kanji glyphs — for "見える" with ruby み on 見, the
    // headword is just 見, not the whole word. The envelope spans the full segment ∪ ruby, since selection / hit-testing
    // reuses it.
    //
    // Heights are standardized to font lineHeight so all rects on a line look uniform.
    static func segments(_ inputs: Inputs) -> [SegmentGeometry] {
        let headwordHeight = ceil(inputs.baseFont.lineHeight)
        // Reserve a ruby row only when furigana is visible. Otherwise the envelope
        // collapses to headword height — toggling furigana OFF visually shrinks every
        // envelope, instead of leaving an empty ruby band that no longer matches reality.
        let rubyHeight = inputs.isFuriganaVisible ? ceil(inputs.furiganaFont.lineHeight) : 0
        return inputs.segmentNSRanges.flatMap { segRange -> [SegmentGeometry] in
            guard let segRect = inputs.firstRectByNSRange[segRange] else { return [] }
            // Every kanji run in the segment, left to right: 憤り出しました has two (憤, 出), and
            // each gets its own headword rect, ruby rect and bisector.
            let runs: [(rect: CGRect, reading: String)] = inputs.kanjiRunRectByLocation
                .filter { NSLocationInRange($0.key, segRange) }
                .sorted { $0.key < $1.key }
                .compactMap { kanjiLoc, kanjiRect in
                    guard inputs.kanjiRunLengthByLocation[kanjiLoc] != nil,
                          let reading = inputs.readingByLocation[kanjiLoc],
                          reading.isEmpty == false else { return nil }
                    return (kanjiRect, reading)
                }

            // One headword rect per run (tight around its kanji glyphs), or the whole segment
            // when it has no run; the bisector is its centre and the ruby is centred on it —
            // above the kanji, not the segment, so okurigana doesn't shift it. No ruby rect while
            // furigana is hidden: it would mark content that isn't on screen.
            let parts: [(headword: CGRect, furigana: CGRect?)] = (runs.isEmpty ? [(segRect, "")] : runs).map { run in
                let headwordRect = CGRect(
                    x: run.rect.origin.x,
                    y: run.rect.maxY - headwordHeight,
                    width: run.rect.width,
                    height: headwordHeight
                )
                guard inputs.isFuriganaVisible, run.reading.isEmpty == false else { return (headwordRect, nil) }
                let rubyWidth = ceil((run.reading as NSString).size(withAttributes: [.font: inputs.furiganaFont]).width)
                return (headwordRect, CGRect(
                    x: headwordRect.midX - rubyWidth / 2,
                    y: headwordRect.minY - rubyHeight,
                    width: rubyWidth,
                    height: rubyHeight
                ))
            }

            // Envelope = horizontal bounding box of the segment and all its ruby × (headword
            // height + ruby band when ruby exists). Ruby wider than its kanji (ものがたり over
            // 物語) can reach past the segment; the envelope grows to contain it. Without ruby the
            // band collapses to zero, so hit-testing doesn't register taps in empty space.
            let rubyRects = parts.compactMap(\.furigana)
            let envelopeMinX = rubyRects.reduce(segRect.minX) { min($0, $1.minX) }
            let envelopeMaxX = rubyRects.reduce(segRect.maxX) { max($0, $1.maxX) }
            let effectiveRubyHeight = rubyRects.isEmpty ? 0 : rubyHeight
            let envelope = CGRect(
                x: envelopeMinX,
                y: segRect.maxY - headwordHeight - effectiveRubyHeight,
                width: envelopeMaxX - envelopeMinX,
                height: headwordHeight + effectiveRubyHeight
            )

            return parts.map { part in
                SegmentGeometry(
                    location: segRange.location,
                    headwordRect: part.headword,
                    furiganaRect: part.furigana,
                    envelopeRect: envelope,
                    bisectorX: part.headword.midX
                )
            }
        }
    }

    // Builds the per-line geometry used by the line-band debug toggles.
    static func lines(_ inputs: Inputs) -> [LineGeometry] {
        inputs.lineFrames.map {
            LineGeometry(frame: $0, furiganaBandHeight: inputs.furiganaBandHeight, furiganaGap: inputs.furiganaGap)
        }
    }
}

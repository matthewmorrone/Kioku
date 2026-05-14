import UIKit
import CoreText

// Segment-packed layout: bypass CTTypesetter's word-wrap and lay segments out as
// atomic units whose footprint width = max(headword, ruby). This is what enables the
// "ruby spacing on" mode's spec:
//
//   - First segment per line sits flush at the left content inset (footprint left = inset).
//   - Adjacent segments touch with zero gap between footprints.
//   - Furigana and headword are positioned together; the wrap decision considers the
//     whole footprint, so neither half ever ends up on a different line from the other.
//
// Off mode keeps using KiokuTextLayoutEngine's CTTypesetter-based path. This file is
// only consulted when the renderer is in ruby-spacing-on mode.
//
// What we DON'T do here:
//  - Color / kern attributes already live in the attributed string and are honored when
//    we build per-segment CTLines downstream.
//  - Drawing — this file produces placements; KiokuCoreTextView walks them in draw().
//  - Tap routing — KiokuTextLayoutEngine consults the placements when in this mode.
enum KiokuSegmentPackedLayout {

    // One placed segment in the packed layout.
    struct Placement: Equatable {
        // UTF-16 location/length in the source attributed string. Matches one entry from
        // the input segment NSRange list.
        let location: Int
        let length: Int
        // 0-based line index assigned by the packer.
        let lineIndex: Int
        // Footprint origin = where the segment's "atomic unit" left edge sits. The
        // footprint is [originX, originX+footprintWidth) and contains every visible
        // pixel of headword + all ruby annotations within the segment.
        let originX: CGFloat
        // Total footprint width = headwordWidth + leftOverhang + rightOverhang. The
        // packer advances cursorX by this amount when placing adjacent segments.
        let footprintWidth: CGFloat
        // Typographic advance of the segment's surface in the body font (including the
        // base `.kern` from the attributed string). Does NOT include ruby overhang.
        let headwordWidth: CGFloat
        // The widest ruby annotation inside this segment (the headline number used by
        // tests / debug overlays). Note: this is the WIDEST ruby, not necessarily the
        // ruby that determines the overhang — overhang depends on where in the segment
        // the kanji-run sits, not just on ruby width.
        let rubyWidth: CGFloat
        // How far the leftmost ruby overhangs past the headword's left edge. Adding this
        // to `originX` gives the headword's draw position; the headword is offset INTO
        // the footprint by this amount so ruby on the leftmost kanji-run fits at the
        // footprint's left edge.
        let leftOverhang: CGFloat
        // How far the rightmost ruby overhangs past the headword's right edge.
        let rightOverhang: CGFloat
    }

    // One line of the packed layout.
    struct LineLayout: Equatable {
        let lineIndex: Int
        // Top of the line box (UIKit coords, top-down).
        let originY: CGFloat
        // ascent + descent + leading.
        let height: CGFloat
        // ascent only — the glyph baseline = originY + ascent.
        let ascent: CGFloat
    }

    struct Result: Equatable {
        let placements: [Placement]
        let lines: [LineLayout]
        let contentSize: CGSize
    }

    struct Inputs {
        // Source attributed string. The packer measures headword widths by typesetting a
        // CTLine from each segment's attributed substring — that CTLine's typographic
        // bounds include `.kern` and any other layout-affecting attributes the builder
        // injects, which a plain `NSString.size` measurement would miss. (Earlier impl
        // used NSString.size and adjacent headwords overlapped by ~kerning × charCount.)
        let attributedString: NSAttributedString
        // UTF-16 ranges of segments to place, in document order. Newline characters in
        // any segment force a line break before the next segment.
        let segmentNSRanges: [NSRange]
        // Furigana keyed by KANJI-RUN UTF-16 location (not segment location). The packer
        // measures ruby widths to compute footprints; the renderer reuses these to draw.
        let furiganaByLocation: [Int: String]
        let furiganaLengthByLocation: [Int: Int]
        let baseFont: UIFont
        let furiganaFont: UIFont
        // Available content width (already minus content insets).
        let availableWidth: CGFloat
        // Top of line 0 (already includes contentInset.top + ruby reserve).
        let topInset: CGFloat
        // Extra vertical space added between consecutive lines.
        let interLineGap: CGFloat
        // Horizontal origin of every line (typically contentInset.left).
        let leftInset: CGFloat
    }

    // Walks segments left-to-right, packing each into the current line if its footprint
    // fits in the remaining width; otherwise wraps to a new line. Newline characters
    // inside a segment surface force an immediate line break before the NEXT segment is
    // placed (the segment containing the newline still gets placed on the current line).
    static func pack(_ inputs: Inputs) -> Result {
        let nsString = inputs.attributedString.string as NSString
        let lineHeight = inputs.baseFont.lineHeight
        // UIFont exposes ascender (positive) and descender (negative). Use `ascender`.
        let lineAscent = inputs.baseFont.ascender

        var placements: [Placement] = []
        var lines: [LineLayout] = []

        var lineIndex = 0
        var cursorX = inputs.leftInset
        var lineOriginY = inputs.topInset

        // Helper: flush the current line into `lines` if any placements landed on it,
        // then advance to the next line.
        func startNewLine() {
            lines.append(LineLayout(
                lineIndex: lineIndex,
                originY: lineOriginY,
                height: lineHeight,
                ascent: lineAscent
            ))
            lineIndex += 1
            cursorX = inputs.leftInset
            lineOriginY += lineHeight + inputs.interLineGap
        }

        for segRange in inputs.segmentNSRanges {
            guard segRange.location != NSNotFound, segRange.length > 0 else { continue }
            guard segRange.location + segRange.length <= nsString.length else { continue }
            let surface = nsString.substring(with: segRange)

            // Pure-newline segment: force a line break, no placement.
            if surface == "\n" || surface == "\r\n" || surface == "\r" {
                if cursorX > inputs.leftInset {
                    // We had content on this line — finalize it before wrapping.
                    startNewLine()
                } else {
                    // Empty line (blank line in the source). Still advance one line.
                    startNewLine()
                }
                continue
            }

            // Measure headword via the CTLine that the renderer will actually draw — this
            // includes `.kern` from the attributed string. Using NSString.size here would
            // undershoot the rendered width by `.kern × charCount` and adjacent headwords
            // would overlap by that amount.
            let segAttr = inputs.attributedString.attributedSubstring(from: segRange)
            let segLine = CTLineCreateWithAttributedString(segAttr as CFAttributedString)
            let headwordWidth = ceil(CGFloat(CTLineGetTypographicBounds(segLine, nil, nil, nil)))
            // Compute per-kanji-run ruby overhang on each side of the segment. For a
            // segment like 美しい with ruby うつく on just 美 (the first kanji), ruby
            // extends to the LEFT past 美's center by (rubyWidth − kanjiWidth)/2 — and
            // since 美 sits at the segment's left edge, that overhang crosses the
            // segment's left boundary. Without tracking it, the footprint underestimates
            // the segment's visual width and ruby renders past the inset.
            let overhang = rubyOverhang(
                segRange: segRange,
                segLine: segLine,
                furiganaByLocation: inputs.furiganaByLocation,
                furiganaLengthByLocation: inputs.furiganaLengthByLocation,
                attributedString: inputs.attributedString,
                furiganaFont: inputs.furiganaFont,
                headwordWidth: headwordWidth
            )
            let rubyWidth = overhang.widestRubyWidth
            let footprintWidth = headwordWidth + overhang.left + overhang.right

            // Wrap if this segment won't fit on the current line. First segment on any
            // line is always placed even when it overflows — otherwise an oversized
            // single segment would loop forever.
            if cursorX > inputs.leftInset && cursorX + footprintWidth > inputs.leftInset + inputs.availableWidth {
                startNewLine()
            }

            placements.append(Placement(
                location: segRange.location,
                length: segRange.length,
                lineIndex: lineIndex,
                originX: cursorX,
                footprintWidth: footprintWidth,
                headwordWidth: headwordWidth,
                rubyWidth: rubyWidth,
                leftOverhang: overhang.left,
                rightOverhang: overhang.right
            ))
            cursorX += footprintWidth

            // Embedded newline inside a non-pure-newline surface (rare, but handle
            // gracefully): force a wrap after placing.
            if surface.contains("\n") {
                startNewLine()
            }
        }

        // Finalize the last line if it had content.
        if cursorX > inputs.leftInset {
            startNewLine()
        }

        let totalHeight = lines.last.map { $0.originY + $0.height } ?? lineOriginY
        // contentSize.width is the right edge of the widest line — which we haven't
        // tracked per-line. For the packer, the right edge of any placement's footprint
        // is the relevant bound.
        let maxRight = placements.reduce(inputs.leftInset) { acc, p in
            max(acc, p.originX + p.footprintWidth)
        }
        return Result(
            placements: placements,
            lines: lines,
            contentSize: CGSize(width: maxRight, height: totalHeight)
        )
    }

    // Measures the full typographic advance of a string in the given font. Uses NSString
    // sizing so .kern from the attributed string isn't counted — we want the raw glyph
    // width because in segment-packed mode we control inter-segment spacing ourselves.
    private static func measureWidth(of text: String, font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    // For each ruby annotation in the segment, measures how far the centered ruby would
    // overhang the segment's left/right edge. Returns the MAX overhang on each side and
    // the widest ruby width (for record-keeping in Placement).
    //
    // Why per-run, not just max ruby width: a ruby sits over a SPECIFIC kanji-run inside
    // the segment, not over the whole segment. For 美しい with ruby うつく on 美 (the
    // leftmost char), the ruby is centered on 美 — which means it overhangs the segment's
    // left edge but NOT its right edge. A naive `max(headwordWidth, rubyWidth)` footprint
    // would assume centered-over-segment and miss the asymmetric overhang.
    private static func rubyOverhang(
        segRange: NSRange,
        segLine: CTLine,
        furiganaByLocation: [Int: String],
        furiganaLengthByLocation: [Int: Int],
        attributedString: NSAttributedString,
        furiganaFont: UIFont,
        headwordWidth: CGFloat
    ) -> (left: CGFloat, right: CGFloat, widestRubyWidth: CGFloat) {
        var leftMax: CGFloat = 0
        var rightMax: CGFloat = 0
        var widestRuby: CGFloat = 0
        for (rubyLoc, reading) in furiganaByLocation {
            guard NSLocationInRange(rubyLoc, segRange) else { continue }
            guard let rubyLen = furiganaLengthByLocation[rubyLoc], rubyLen > 0 else { continue }
            guard rubyLoc + rubyLen <= segRange.location + segRange.length else { continue }
            // Kanji-run's X position within the segment, via the segment's own CTLine.
            // Local indices are offsets into the segment, not absolute UTF-16 positions.
            let localStart = rubyLoc - segRange.location
            let localEnd = localStart + rubyLen
            let xStart = CGFloat(CTLineGetOffsetForStringIndex(segLine, localStart, nil))
            let xEnd = CGFloat(CTLineGetOffsetForStringIndex(segLine, localEnd, nil))
            let kanjiCenter = (xStart + xEnd) / 2
            let rubyW = ceil(measureWidth(of: reading, font: furiganaFont))
            widestRuby = max(widestRuby, rubyW)
            let rubyLeftInSegment = kanjiCenter - rubyW / 2
            let rubyRightInSegment = kanjiCenter + rubyW / 2
            // Overhang = how far ruby extends past the segment boundary (clamped ≥ 0).
            // Segment occupies [0, headwordWidth) in local coords.
            leftMax = max(leftMax, max(0, -rubyLeftInSegment))
            rightMax = max(rightMax, max(0, rubyRightInSegment - headwordWidth))
        }
        return (left: ceil(leftMax), right: ceil(rightMax), widestRubyWidth: widestRuby)
    }
}

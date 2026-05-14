import UIKit

// Computes per-line X-origin shifts for the CoreText Read renderer so that a line whose
// first segment has wider-than-headword ruby doesn't visually clip the ruby's left edge.
//
// TextKit 2 path solves this with `textContainer.exclusionPaths`, which forces a relayout
// cascade. CoreText path lays out at natural origins and then shifts the line right by
// the overhang amount — no retypesetting, just a cheap origin update on the engine.
//
// This is a pure value-typed computation so it can be unit-tested without a UIView host.
enum KiokuWideRubyLineInset {

    struct Inputs {
        // Lines AFTER layout. Each line.stringRange tells us its first UTF-16 location.
        let lineStringStarts: [Int]
        // All segment NSRanges in document order.
        let segmentNSRanges: [NSRange]
        // Reading per segment location (UTF-16). Missing key = no ruby = no overhang.
        let readingByLocation: [Int: String]
        let baseFont: UIFont
        let furiganaFont: UIFont
        // Optional cached widths the caller may compute once per layout. Pass nil to let
        // this helper measure on the fly. Keyed by `surface` string.
        let kanjiWidthOverrides: [String: CGFloat]
    }

    // Builds the [lineIndex: shiftX] map. Lines whose first segment has no overhang are
    // omitted so callers can apply the dictionary directly to `KiokuTextLayoutEngine.setLineOriginShifts`.
    static func shifts(for inputs: Inputs, sourceText: String) -> [Int: CGFloat] {
        guard inputs.lineStringStarts.isEmpty == false,
              inputs.segmentNSRanges.isEmpty == false,
              inputs.readingByLocation.isEmpty == false else { return [:] }
        let nsString = sourceText as NSString
        var result: [Int: CGFloat] = [:]

        for (lineIndex, lineStart) in inputs.lineStringStarts.enumerated() {
            // The first segment on this line is the lowest-location segment whose NSRange
            // intersects [lineStart, lineEnd]. The line's stringRange exactly identifies
            // its first character, and segments are stable in document order, so a linear
            // scan is fine — typical note has <200 segments.
            guard let segmentRange = firstSegmentAt(line: lineStart, in: inputs.segmentNSRanges) else { continue }
            guard let reading = inputs.readingByLocation[segmentRange.location],
                  reading.isEmpty == false else { continue }
            // Only segments that actually start at the line's left edge cause overhang.
            // A segment that started on the previous line and wrapped onto this one has
            // its ruby anchored above the previous line's tail, not this one's head.
            guard segmentRange.location == lineStart else { continue }

            let kanji = nsString.substring(with: segmentRange)
            let kanjiWidth: CGFloat = inputs.kanjiWidthOverrides[kanji]
                ?? measureWidth(text: kanji, font: inputs.baseFont)
            let furiganaWidth = measureWidth(text: reading, font: inputs.furiganaFont)
            let overhang = (furiganaWidth - kanjiWidth) / 2
            guard overhang > 0 else { continue }
            result[lineIndex] = ceil(overhang)
        }
        return result
    }

    // Returns the first segment NSRange whose location is at the given line start. Returns
    // nil when no segment begins exactly at the line start.
    private static func firstSegmentAt(line lineStart: Int, in ranges: [NSRange]) -> NSRange? {
        ranges.first { $0.location == lineStart }
    }

    // Typographic width of `text` at `font`, ceiled to whole points. Used for width-based
    // shift estimation when CT's image bounds don't expose ruby annotation extent.
    private static func measureWidth(text: String, font: UIFont) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        return ceil(attributed.size().width)
    }
}

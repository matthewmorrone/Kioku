import UIKit

// Picks the font size a breakdown card's Japanese line is drawn at so it fits on one line instead
// of wrapping: the full size when it already fits, smaller when it doesn't, never below
// `minimumScale` of the full size (a line too long even then wraps at that size rather than
// shrinking into illegibility). Pure measurement, shared by SongLineCard's plain-text branch and
// its CoreText furigana branch.
enum SongLineFitSize {
    static let minimumScale: CGFloat = 0.4
    // Headroom on the measured width for what the estimate leaves out (the renderer's ruby
    // spacing and glyph overhang), so a line right at the edge doesn't wrap anyway.
    static let widthSafetyMargin: CGFloat = 1.03

    // The fitted size for `text` drawn in `font(size)` within `availableWidth`. With furigana,
    // each segment is as wide as the wider of its headword and its ruby (rubyScale of the size),
    // matching the renderer's segment packing; without, the plain string width.
    static func size(
        for text: String,
        baseSize: CGFloat,
        availableWidth: CGFloat,
        font: (CGFloat) -> UIFont,
        segmentationRanges: [Range<String.Index>] = [],
        furiganaBySegmentLocation: [Int: String] = [:],
        rubyScale: CGFloat = 0.5
    ) -> CGFloat {
        guard availableWidth > 0, text.isEmpty == false else { return baseSize }
        let natural = widthSafetyMargin * naturalWidth(
            of: text,
            font: font(baseSize),
            rubyFont: UIFont.systemFont(ofSize: baseSize * rubyScale),
            segmentationRanges: segmentationRanges,
            furiganaBySegmentLocation: furiganaBySegmentLocation
        )
        guard natural > availableWidth else { return baseSize }
        return baseSize * max(minimumScale, availableWidth / natural)
    }

    // The line's one-line width at the base size. Segments come from the furigana cache; when
    // they don't cover the whole text, the plain string width is used instead.
    private static func naturalWidth(
        of text: String,
        font: UIFont,
        rubyFont: UIFont,
        segmentationRanges: [Range<String.Index>],
        furiganaBySegmentLocation: [Int: String]
    ) -> CGFloat {
        // One-line glyph width of a string in a font.
        func width(_ string: String, _ font: UIFont) -> CGFloat {
            (string as NSString).size(withAttributes: [.font: font]).width
        }
        let covered = segmentationRanges.reduce(0) { $0 + text.distance(from: $1.lowerBound, to: $1.upperBound) }
        guard segmentationRanges.isEmpty == false, covered == text.count else { return width(text, font) }
        var total: CGFloat = 0
        for range in segmentationRanges {
            let start = range.lowerBound.utf16Offset(in: text)
            let end = range.upperBound.utf16Offset(in: text)
            let ruby = furiganaBySegmentLocation
                .filter { $0.key >= start && $0.key < end }
                .sorted { $0.key < $1.key }
                .map(\.value)
                .joined()
            total += max(width(String(text[range]), font), width(ruby, rubyFont))
        }
        return total
    }
}

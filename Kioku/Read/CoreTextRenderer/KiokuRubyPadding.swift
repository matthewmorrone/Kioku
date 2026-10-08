import CoreGraphics
import CoreText
import Foundation
import UIKit

// Space added inside a segment so a kanji run's ruby doesn't overhang its own kana (憤り with
// いきどお: the ruby is twice 憤's width, so 憤 is padded on both sides). The padding is .kern on
// the character before the run and on the run's last character. .kern widens a glyph's advance, and
// the ruby must centre on the kanji alone, so runs are measured from glyph positions (kanjiSpan)
// with the last character's kern taken off — not from caret offsets: CoreText puts the caret
// between two glyphs halfway through the first one's kern, so offsets can't tell where a kerned
// kanji ends.
nonisolated enum KiokuRubyPadding {
    // Where the glyphs of characters [localStart, localEnd) sit in `line` (built from `segment`):
    // from the first glyph's position to the last glyph's position plus its advance, less the
    // .kern on its character. That kern is all space after the glyph (the reader's kerning plus any
    // ruby padding or segment spacing), so leaving any of it in would centre the ruby right of the
    // kanji by half of it. nil when the line has no glyph for an end of the range.
    static func kanjiSpan(in line: CTLine, segment: NSAttributedString, localStart: Int, localEnd: Int) -> (start: CGFloat, end: CGFloat)? {
        var start: CGFloat?
        var end: CGFloat?
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            for glyph in 0..<count {
                if indices[glyph] == localStart, start == nil { start = positions[glyph].x }
                if indices[glyph] == localEnd - 1 {
                    end = positions[glyph].x + advances[glyph].width - kern(in: segment, at: localEnd - 1)
                }
            }
        }
        guard let start, let end else { return nil }
        return (start, end)
    }

    // Blank space on each side of a character's glyph (advance minus ink), so ruby padding can butt
    // ink against ink instead of advance box against advance box. 0 for a character the font has no
    // glyph for, or one without ink, which keeps the padding at its full advance-based amount.
    static func sideBearings(of character: unichar, font: UIFont) -> (left: CGFloat, right: CGFloat) {
        let ctFont = font as CTFont
        var utf16 = character
        var glyph: CGGlyph = 0
        guard CTFontGetGlyphsForCharacters(ctFont, &utf16, &glyph, 1) else { return (0, 0) }
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &glyph, &bounds, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        guard bounds.isEmpty == false else { return (0, 0) }
        return (max(0, bounds.minX), max(0, advance.width - bounds.maxX))
    }

    // The .kern on the character at `index`, 0 when none.
    private static func kern(in segment: NSAttributedString, at index: Int) -> CGFloat {
        guard index >= 0, index < segment.length else { return 0 }
        return segment.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat ?? 0
    }
}

import CoreGraphics
import CoreText
import Foundation

// Space added inside a segment so a kanji run's ruby doesn't overhang its own kana (憤り with
// いきどお: the ruby is twice 憤's width, so 憤 is padded on both sides). The padding is .kern on
// the character before the run and on the run's last character; the amount on the last character
// is also recorded under `key`, because .kern widens the glyph's advance and the ruby must centre on
// the kanji alone. Runs are measured from glyph positions (kanjiSpan), not caret offsets: CoreText
// puts the caret between two glyphs halfway through the first one's kern, so offsets can't tell
// where a kerned kanji ends.
nonisolated enum KiokuRubyPadding {
    static let key = NSAttributedString.Key("KiokuRubyPadding")

    // The padding recorded on the character at `index` (a kanji run's last character), 0 when none.
    static func trailingPadding(in string: NSAttributedString, at index: Int) -> CGFloat {
        guard index >= 0, index < string.length else { return 0 }
        return string.attribute(key, at: index, effectiveRange: nil) as? CGFloat ?? 0
    }

    // Where the glyphs of characters [localStart, localEnd) sit in `line` (built from `segment`):
    // from the first glyph's position to the last glyph's position plus its advance, less the ruby
    // padding recorded on it. nil when the line has no glyph for an end of the range.
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
                    end = positions[glyph].x + advances[glyph].width - trailingPadding(in: segment, at: localEnd - 1)
                }
            }
        }
        guard let start, let end else { return nil }
        return (start, end)
    }
}

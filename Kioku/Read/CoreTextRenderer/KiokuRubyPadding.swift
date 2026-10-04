import CoreGraphics
import Foundation

// Space added inside a segment so a kanji run's ruby doesn't overhang its own kana (憤り with
// いきどお: the ruby is twice 憤's width, so 憤 is padded on both sides). The padding is .kern on
// the character before the run and on the run's last character; the amount on the last character
// is also recorded under `key`, because .kern adds space AFTER a glyph, and the ruby centring
// (which measures the run by string offsets) must not count that space as part of the kanji.
nonisolated enum KiokuRubyPadding {
    static let key = NSAttributedString.Key("KiokuRubyPadding")

    // The padding recorded on the character at `index` (a kanji run's last character), 0 when none.
    static func trailingPadding(in string: NSAttributedString, at index: Int) -> CGFloat {
        guard index >= 0, index < string.length else { return 0 }
        return string.attribute(key, at: index, effectiveRange: nil) as? CGFloat ?? 0
    }
}

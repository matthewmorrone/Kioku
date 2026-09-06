import Foundation

// Shared by KiokuCoreTextAttributedStringBuilder (paragraph-mode ruby, which makes room by
// kerning apart the segments on either side of an overhanging run) and FuriganaView (single-word
// ruby, which kerns its own internal runs the same way and falls back to widening itself only at
// a run with no neighboring character to push). Both were computing "how far does this ruby
// annotation extend past its own base run" independently before this was extracted — one formula
// instead of two copies that could silently drift apart, which is exactly what made it unclear
// whether a clipping fix in one renderer also covered the other.
enum RubyOverhang {
    // Returns how far a ruby (furigana) annotation extends past ONE side of its base run, given
    // the base run's rendered width and the ruby's own rendered width. The ruby draws centered
    // over its base run, so the overhang is split evenly between the two sides — this returns
    // that per-side half. 0 when the ruby isn't wider than its base run.
    static func margin(baseWidth: CGFloat, rubyWidth: CGFloat) -> CGFloat {
        max(0, ceil((rubyWidth - baseWidth) / 2))
    }
}

import CoreText
import UIKit

// The body font for rendered Japanese text (Read tab, lyrics view): the system font with CJK
// punctuation — 、。「」！？（）・ — left in its standard full-width box, so the empty half of
// the box separates the mark from the next character the way Japanese typesetting expects.
// Every body-text measurement uses this same font, so layout, hit-testing and drawing agree on
// widths.
enum ReadingFont {
    // Body font at `size` with full-width punctuation.
    static func body(size: CGFloat) -> UIFont {
        UIFont.systemFont(ofSize: size)
    }
}

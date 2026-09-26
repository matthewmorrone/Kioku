import CoreText
import UIKit

// The body font for rendered Japanese text (Read tab, lyrics view): the system font with the
// OpenType "halt" feature on, which sets CJK punctuation — 、。「」！？（）・ — in half-width boxes
// instead of full ones, the way Japanese typesetting squeezes 約物. The text itself keeps its
// standard full-width characters. Every body-text measurement uses this same font, so layout,
// hit-testing and drawing agree on widths.
enum ReadingFont {
    // Body font at `size` with half-width punctuation.
    static func body(size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size)
        let settings: [[UIFontDescriptor.FeatureKey: Any]] = [[
            UIFontDescriptor.FeatureKey(kCTFontOpenTypeFeatureTag as String): "halt",
            UIFontDescriptor.FeatureKey(kCTFontOpenTypeFeatureValue as String): 1,
        ]]
        return UIFont(descriptor: base.fontDescriptor.addingAttributes([.featureSettings: settings]), size: size)
    }
}

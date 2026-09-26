import UIKit

// The colors rendered Japanese text is drawn with — segment alternation, the tap-selection
// highlight, and the three Saved Highlight states. With Custom Text Colors off every one comes
// from the active theme; with it on, the user's stored hexes replace them. The Read view, the
// lyrics view and the Settings preview all resolve through here so they can't disagree.
struct ReadingColors {
    let evenSegment: UIColor
    let oddSegment: UIColor
    let selectionHighlight: UIColor
    let saved: UIColor
    let savedLearned: UIColor
    let savedNotLearned: UIColor

    // Resolves the colors from the Custom Text Colors toggle and its stored hexes. Callers pass
    // their own @AppStorage values (rather than this reading UserDefaults) so SwiftUI tracks
    // the keys and re-renders on a change. An unparseable custom hex falls back to the theme's.
    static func resolve(
        customEnabled: Bool,
        colorAHex: String,
        colorBHex: String,
        highlightHex: String,
        savedHex: String,
        savedLearnedHex: String,
        savedNotLearnedHex: String,
        palette: ThemePalette = Theme.activePalette
    ) -> ReadingColors {
        // Picks the custom hex when customization is on and it parses, else the theme's hex.
        func color(_ custom: String, _ themed: String, fallback: UIColor) -> UIColor {
            if customEnabled, let parsed = UIColor(hexString: custom) { return parsed }
            return UIColor(hexString: themed) ?? fallback
        }
        return ReadingColors(
            evenSegment: color(colorAHex, palette.defaultTokenColorAHex, fallback: .label),
            oddSegment: color(colorBHex, palette.defaultTokenColorBHex, fallback: .secondaryLabel),
            selectionHighlight: color(highlightHex, palette.defaultHighlightHex, fallback: .systemYellow),
            saved: color(savedHex, palette.defaultSavedHex, fallback: .systemOrange),
            savedLearned: color(savedLearnedHex, palette.defaultSavedLearnedHex, fallback: .systemGreen),
            savedNotLearned: color(savedNotLearnedHex, palette.defaultSavedNotLearnedHex, fallback: .systemPurple)
        )
    }
}

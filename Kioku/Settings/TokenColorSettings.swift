import Foundation

// Persistent settings for user-configured segment alternation colors in read mode, plus the two
// coordinating "highlight" colors: the favorited-word glow and the tap-selection box.
enum TokenColorSettings {
    static let enabledKey = "tokenColors.enabled"
    static let colorAKey = "tokenColors.colorA"
    static let colorBKey = "tokenColors.colorB"
    // One highlight color, shared by the favorited-word glow and the tap-selection box (the box
    // renders it at ~0.35 alpha).
    static let highlightColorKey = "tokenColors.highlight"
    // Per-Learned-state colors for the Read tab's Favorited Highlight display option — always
    // literal (not gated behind Custom Token Colors, and NOT theme-derived like colorA/colorB/
    // highlight above), since Favorited Highlight has its own on/off toggle in the Read toolbar
    // and needs to read the same regardless of theme or Custom Token Colors state.
    static let favoritedFavoriteColorKey = "tokenColors.favoritedFavorite"
    static let favoritedLearnedColorKey = "tokenColors.favoritedLearned"
    static let favoritedNotLearnedColorKey = "tokenColors.favoritedNotLearned"
    // "Saved under a different note" — the pre-existing hollow-yellow star's in-text
    // counterpart, orthogonal to Learned state. Same literal/always-available treatment as the
    // three colors above.
    static let favoritedElsewhereColorKey = "tokenColors.favoritedElsewhere"

    // Seed values used as the @AppStorage default for the custom-color keys. They only matter
    // until the user picks their own color — the active theme's defaults drive colorA/colorB/
    // highlight otherwise (see Theme.activePalette); the favorited* colors have no theme-derived
    // default and always start from these.
    static let defaultColorAHex = "#FF9500"                // orange
    static let defaultColorBHex = "#32ADE6"                // cyan
    static let defaultHighlightHex = "#FFD60A"              // gold
    static let defaultFavoritedFavoriteHex = "#FFD60A"      // yellow/gold
    static let defaultFavoritedLearnedHex = "#34C759"       // green
    static let defaultFavoritedNotLearnedHex = "#AF52DE"    // purple
    static let defaultFavoritedElsewhereHex = "#FF9500"     // orange
}

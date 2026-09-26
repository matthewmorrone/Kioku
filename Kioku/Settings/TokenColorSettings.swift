import Foundation

// Persistent keys for the Custom Text Colors overrides (Settings → Customize Colors → Text):
// the segment alternation pair, the tap-selection highlight, and the three Saved Highlight
// colors. With `enabledKey` off none of these are read — the active theme supplies every one
// (see ReadingColors).
enum TokenColorSettings {
    static let enabledKey = "tokenColors.enabled"
    static let colorAKey = "tokenColors.colorA"
    static let colorBKey = "tokenColors.colorB"
    // The tap-selection box color (rendered at ~0.35 alpha).
    static let highlightColorKey = "tokenColors.highlight"
    // Per-state colors for the Read toolbar's Saved Highlight option: every saved word,
    // Learned words, and saved-but-not-Learned words.
    static let savedColorKey = "tokenColors.saved"
    static let savedLearnedColorKey = "tokenColors.savedLearned"
    static let savedNotLearnedColorKey = "tokenColors.savedNotLearned"

    // @AppStorage defaults for the keys above. Turning Custom Text Colors on overwrites all six
    // with the active theme's colors, so these only show if a key is read before that.
    static let defaultColorAHex = "#FF9500"                // orange
    static let defaultColorBHex = "#32ADE6"                // cyan
    static let defaultHighlightHex = "#FFD60A"              // gold
    static let defaultSavedHex = "#FFD60A"                  // yellow/gold
    static let defaultSavedLearnedHex = "#34C759"           // green
    static let defaultSavedNotLearnedHex = "#AF52DE"        // purple
}

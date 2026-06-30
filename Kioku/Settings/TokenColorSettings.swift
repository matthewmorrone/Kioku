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

    // Seed values used as the @AppStorage default for the three custom-color keys. They only
    // matter when the user enables Custom Token Colors and hasn't picked a color yet — the
    // active theme's defaults drive every other case (see Theme.activePalette).
    static let defaultColorAHex = "#FF9500"       // orange
    static let defaultColorBHex = "#32ADE6"       // cyan
    static let defaultHighlightHex = "#FFD60A"    // gold
}

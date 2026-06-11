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

    // Default colors match Kyouku's palette for familiarity.
    static let defaultColorAHex = "#FF9500"       // orange
    static let defaultColorBHex = "#32ADE6"       // cyan
    static let defaultHighlightHex = "#FFD60A"    // gold

    // Curated palettes — each is high-contrast and reads well on light and dark backgrounds, and
    // carries a coordinating highlight color so the glow/selection match the segment pair. Tapping
    // one in Settings applies all three and turns custom token colors on.
    struct Preset: Identifiable {
        var id: String { name }
        let name: String
        let aHex: String
        let bHex: String
        let highlightHex: String
    }

    // Each highlight is chosen to complete the pair as a triad — visibly distinct from both
    // token colors (it marks glow/selection, not a third token) and unique across presets.
    static let presets: [Preset] = [
        Preset(name: "Classic", aHex: "#FF9500", bHex: "#32ADE6", highlightHex: "#FFD60A"),  // gold
        Preset(name: "Coral",   aHex: "#FF6B6B", bHex: "#1ABC9C", highlightHex: "#FFE066"),  // soft yellow
        Preset(name: "Berry",   aHex: "#E84393", bHex: "#00B894", highlightHex: "#FFD43B"),  // amber
        Preset(name: "Dusk",    aHex: "#E8B339", bHex: "#5C6BC0", highlightHex: "#FF8FAB"),  // rose
        // Bloom's old #FFE066 duplicated Coral's highlight; mint completes the pink/blue triad.
        Preset(name: "Bloom",   aHex: "#F06595", bHex: "#4DABF7", highlightHex: "#8CE99A"),  // mint
        Preset(name: "Ember",   aHex: "#FB8C45", bHex: "#9775FA", highlightHex: "#74F0C8"),  // aqua
    ]
}

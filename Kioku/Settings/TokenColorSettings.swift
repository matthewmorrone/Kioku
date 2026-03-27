import Foundation

// Persistent settings for user-configured segment alternation colors in read mode.
enum TokenColorSettings {
    static let enabledKey = "tokenColors.enabled"
    static let colorAKey = "tokenColors.colorA"
    static let colorBKey = "tokenColors.colorB"

    // Default colors match Kyouku's palette for familiarity.
    static let defaultColorAHex = "#FF9500"  // orange
    static let defaultColorBHex = "#32ADE6"  // cyan
}

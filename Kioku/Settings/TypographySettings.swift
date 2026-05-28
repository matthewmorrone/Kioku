import Foundation

enum TypographySettings {
    static let textSizeKey = "kioku.settings.textSize"
    static let lineSpacingKey = "kioku.settings.lineSpacing"
    static let kerningKey = "kioku.settings.kerning"
    static let furiganaGapKey = "kioku.settings.furiganaGap"
    // When `customFuriganaSizeEnabled` is on, `furiganaSize` overrides the implicit
    // headword * 0.5 ratio so the user can pick a furigana font size independently.
    // Off (default) preserves the legacy `textSize * 0.5` derivation everywhere.
    static let customFuriganaSizeEnabledKey = "kioku.settings.customFuriganaSizeEnabled"
    static let furiganaSizeKey = "kioku.settings.furiganaSize"

    static let defaultTextSize = 18.0
    static let defaultLineSpacing = 6.0
    static let defaultKerning = 1.0
    static let defaultFuriganaGap = 2.0
    // Matches `defaultTextSize * 0.5` so flipping the toggle on is initially a no-op.
    static let defaultFuriganaSize = 9.0

    static let textSizeRange = 12.0...36.0
    static let lineSpacingRange = 0.0...24.0
    static let kerningRange = 1.0...12.0
    static let furiganaGapRange = 0.0...10.0
    static let furiganaSizeRange = 6.0...24.0
}

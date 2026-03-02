import Foundation

enum TypographySettings {
    static let textSizeKey = "kioku.settings.textSize"
    static let lineSpacingKey = "kioku.settings.lineSpacing"
    static let kerningKey = "kioku.settings.kerning"

    static let defaultTextSize = 18.0
    static let defaultLineSpacing = 6.0
    static let defaultKerning = 0.0

    static let textSizeRange = 12.0...36.0
    static let lineSpacingRange = 0.0...24.0
    static let kerningRange = 0.0...12.0
}

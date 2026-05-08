import Foundation

// Storage keys for read-mode debug overlay toggles.
enum DebugSettings {
    static let pixelRulerKey = "debug.pixelRuler"
    static let furiganaRectsKey = "debug.furiganaRects"
    static let headwordRectsKey = "debug.headwordRects"
    static let envelopeRectsKey = "debug.envelopeRects"
    // Separate band keys so headword and furigana rows can be visualised independently.
    static let headwordLineBandsKey = "debug.lineBands"
    static let furiganaLineBandsKey = "debug.furiganaLineBands"
    // Bisectors are split into two keys so headword (kanji geometric center) and furigana
    // (ruby geometric center) vertical lines can be toggled independently. When both are on,
    // they color-code by alignment; when only one is on, that single line draws in yellow.
    static let bisectorHeadwordKey = "debug.bisector.headword"
    static let bisectorFuriganaKey = "debug.bisector.furigana"
    // Draws a vertical line at the text container's left inset so line-start
    // envelope alignment can be checked against a fixed reference, and dumps
    // numerical positions for every line-start segment to the unified log.
    static let leftInsetGuideKey = "debug.leftInsetGuide"
    static let startupSegmentationDiffsKey = "debug.startupSegmentationDiffs"
}

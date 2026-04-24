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
    static let bisectorsKey = "debug.bisectors"
    // Draws a vertical line at the text container's left inset so line-start
    // envelope alignment can be checked against a fixed reference, and dumps
    // numerical positions for every line-start segment to the unified log.
    static let leftInsetGuideKey = "debug.leftInsetGuide"
    static let startupSegmentationDiffsKey = "debug.startupSegmentationDiffs"
}

import Foundation

// Storage keys for read-mode debug overlay toggles.
enum DebugSettings {
    static let pixelRulerKey = "debug.pixelRuler"
    static let furiganaRectsKey = "debug.furiganaRects"
    static let headwordRectsKey = "debug.headwordRects"
    // Separate band keys so headword and furigana rows can be visualised independently.
    static let headwordLineBandsKey = "debug.lineBands"
    static let furiganaLineBandsKey = "debug.furiganaLineBands"
    static let startupSegmentationDiffsKey = "debug.startupSegmentationDiffs"
}

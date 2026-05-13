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
    // Bisector toggles split into two so misalignment between the headword center
    // (kanji glyph midX) and the ruby center is directly visible. When only one is
    // enabled, the toggle's vertical line draws in that toggle's color; when both
    // are enabled, they coincide for properly-centered ruby.
    static let bisectorHeadwordKey = "debug.bisector.headword"
    static let bisectorFuriganaKey = "debug.bisector.furigana"
    // Draws a vertical line at the text container's left inset so line-start
    // envelope alignment can be checked against a fixed reference, and dumps
    // numerical positions for every line-start segment to the unified log.
    static let leftInsetGuideKey = "debug.leftInsetGuide"
    static let startupSegmentationDiffsKey = "debug.startupSegmentationDiffs"
    // Toggles the experimental CoreText-backed Read renderer (`KiokuCoreTextView`) in place
    // of the TextKit 2 UITextView path. Off by default while the new renderer is being
    // brought up; flip in Settings to A/B against the production renderer.
    static let useCoreTextRendererKey = "debug.useCoreTextRenderer"
}

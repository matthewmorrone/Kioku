import SwiftUI

// Renders the Settings typography preview: the shared CoreText sample (SettingsPreviewRenderer)
// on a rounded card, driven straight from the typography and debug-overlay settings. One view
// so the Settings row and the top of the typography sheet show the identical preview.
struct TypographyPreview: View {
    @AppStorage(TypographySettings.textSizeKey) private var textSize = TypographySettings.defaultTextSize
    @AppStorage(TypographySettings.lineSpacingKey) private var lineSpacing = TypographySettings.defaultLineSpacing
    @AppStorage(TypographySettings.kerningKey) private var kerning = TypographySettings.defaultKerning
    @AppStorage(TypographySettings.furiganaGapKey) private var furiganaGap = TypographySettings.defaultFuriganaGap

    @AppStorage(DebugSettings.pixelRulerKey) private var debugPixelRuler = false
    @AppStorage(DebugSettings.furiganaRectsKey) private var debugFuriganaRects = false
    @AppStorage(DebugSettings.headwordRectsKey) private var debugHeadwordRects = false
    @AppStorage(DebugSettings.headwordLineBandsKey) private var debugHeadwordLineBands = false
    @AppStorage(DebugSettings.furiganaLineBandsKey) private var debugFuriganaLineBands = false
    @AppStorage(DebugSettings.headwordLineNumbersKey) private var debugHeadwordLineNumbers = false
    @AppStorage(DebugSettings.rubyLineNumbersKey) private var debugRubyLineNumbers = false
    @AppStorage(DebugSettings.bisectorHeadwordKey) private var debugBisectorHeadword = false
    @AppStorage(DebugSettings.bisectorFuriganaKey) private var debugBisectorFurigana = false
    @AppStorage(DebugSettings.envelopeRectsKey) private var debugEnvelopeRects = false
    @AppStorage(DebugSettings.leftInsetGuideKey) private var debugLeftInsetGuide = false

    var body: some View {
        SettingsPreviewRenderer(
            textSize: $textSize,
            lineSpacing: lineSpacing,
            kerning: kerning,
            furiganaGap: furiganaGap,
            debugFuriganaRects: debugFuriganaRects,
            debugHeadwordRects: debugHeadwordRects,
            debugHeadwordLineBands: debugHeadwordLineBands,
            debugFuriganaLineBands: debugFuriganaLineBands,
            debugBisectorHeadword: debugBisectorHeadword,
            debugBisectorFurigana: debugBisectorFurigana,
            debugEnvelopeRects: debugEnvelopeRects,
            debugLeftInsetGuide: debugLeftInsetGuide,
            debugPixelRuler: debugPixelRuler,
            debugHeadwordLineNumbers: debugHeadwordLineNumbers,
            debugRubyLineNumbers: debugRubyLineNumbers
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        // Vertical padding for breathing room; negative horizontal padding cancels the
        // renderer's hardcoded textContainerInset.left = 4 so the first glyph sits flush with
        // the card's left edge.
        .padding(.vertical, 8)
        .padding(.horizontal, -4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

import SwiftUI

// Renders a word with per-run furigana. Each kanji run rides its reading in a VStack whose last text
// baseline aligns with the neighbouring kana, so okurigana stays on the baseline.
struct FuriganaText: View {
    let surface: String
    let reading: String?
    // Per-kanji-run furigana from the mirror; nil puts one ruby over the whole surface.
    let rubyRuns: [WordOfTheDayRubyRun]?
    let baseFont: Font
    let rubyFont: Font
    // Colors default to the paper-surface ink used by the home families. The Lock Screen accessory
    // slots pass .primary/.secondary instead so the system's vibrant monochrome rendering keeps the
    // text legible against any wallpaper (the fixed ink colors would wash out on a dark background).
    var baseColor: AnyShapeStyle = AnyShapeStyle(WidgetTheme.ink)
    var rubyColor: AnyShapeStyle = AnyShapeStyle(WidgetTheme.inkSecondary)

    var body: some View {
        let wholeWordRuby = (reading?.isEmpty == false && reading != surface) ? reading : nil
        let segments = rubyRuns ?? [WordOfTheDayRubyRun(text: surface, ruby: wholeWordRuby)]
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if let ruby = segment.ruby {
                    VStack(spacing: 1) {
                        Text(ruby).font(rubyFont).foregroundStyle(rubyColor)
                        Text(segment.text).font(baseFont).foregroundStyle(baseColor)
                    }
                    .fixedSize()
                } else {
                    Text(segment.text).font(baseFont).foregroundStyle(baseColor)
                }
            }
        }
    }
}

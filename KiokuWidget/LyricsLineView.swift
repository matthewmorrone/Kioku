import SwiftUI

// Renders the current lyric line (with furigana) and the next line, labelled NEXT, beneath it. Shared by
// the Lock Screen banner and the expanded Dynamic Island. Layout: the furigana line when it fits
// on one row, else the plain line wrapped to two rows (furigana runs can't wrap), then the next
// line under a NEXT label.
struct LyricsLineView: View {
    let state: LyricsActivityState
    let baseSize: CGFloat
    let rubySize: CGFloat
    let baseColor: AnyShapeStyle
    let rubyColor: AnyShapeStyle

    var body: some View {
        let plain = state.line.map(\.text).joined()
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                FuriganaText(
                    surface: plain,
                    reading: nil,
                    rubyRuns: state.line.map { WordOfTheDayRubyRun(text: $0.text, ruby: $0.ruby) },
                    baseFont: WidgetTheme.japanese(baseSize, bold: true),
                    rubyFont: WidgetTheme.japanese(rubySize),
                    baseColor: baseColor,
                    rubyColor: rubyColor
                )
                .fixedSize()
                Text(plain)
                    .font(WidgetTheme.japanese(baseSize * 0.8, bold: true))
                    .foregroundStyle(baseColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            if let next = state.nextLine {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("NEXT")
                        .font(.system(size: baseSize * 0.4, weight: .bold))
                        .foregroundStyle(rubyColor)
                    Text(next)
                        .font(WidgetTheme.japanese(baseSize * 0.6))
                        .foregroundStyle(rubyColor)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

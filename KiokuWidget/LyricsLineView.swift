import SwiftUI

// Renders the current lyric line (with furigana) and the next line dimmed beneath it, centred. Shared by
// the Lock Screen banner and the expanded Dynamic Island. Layout: the furigana line when it fits
// on one row, else the plain line wrapped to two rows (furigana runs can't wrap), then the next
// line. On each line change both rows push up from the bottom, so the dimmed line visibly rises
// into the current slot — the motion, rather than a label, says which line comes next. Each row
// is identified by its text, which is what makes the system animate it as a new view.
struct LyricsLineView: View {
    let state: LyricsActivityState
    let baseSize: CGFloat
    let rubySize: CGFloat
    let baseColor: AnyShapeStyle
    let rubyColor: AnyShapeStyle

    var body: some View {
        let plain = state.line.map(\.text).joined()
        VStack(alignment: .center, spacing: 4) {
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
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
            }
            .id(plain)
            .transition(.push(from: .bottom))
            if let next = state.nextLine {
                Text(next)
                    .font(WidgetTheme.japanese(baseSize * 0.6))
                    .foregroundStyle(rubyColor)
                    .lineLimit(1)
                    .id(next)
                    .transition(.push(from: .bottom))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

import SwiftUI

// Renders the lyrics Live Activity's Lock Screen banner. Layout: a header row (note title, play
// state), then the current line with furigana and the next line dimmed below it (LyricsLineView).
struct LyricsLiveActivityView: View {
    let title: String
    let state: LyricsActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(WidgetTheme.inkSecondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(WidgetTheme.vermilion)
            }
            LyricsLineView(state: state, baseSize: 24, rubySize: 11,
                           baseColor: AnyShapeStyle(WidgetTheme.ink),
                           rubyColor: AnyShapeStyle(WidgetTheme.inkSecondary))
        }
        .padding(16)
    }
}

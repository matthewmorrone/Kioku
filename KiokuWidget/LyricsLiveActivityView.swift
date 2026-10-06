import SwiftUI

// Renders the lyrics Live Activity's Lock Screen banner on the system's default activity
// background. Layout: a header row (play-state waveform, note title, transport buttons), then the
// current line with furigana and the labelled next line below it (LyricsLineView).
struct LyricsLiveActivityView: View {
    let title: String
    let state: LyricsActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(WidgetTheme.vermilion)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                LyricsActivityControls(isPlaying: state.isPlaying)
            }
            LyricsLineView(state: state, baseSize: 24, rubySize: 11,
                           baseColor: AnyShapeStyle(.primary),
                           rubyColor: AnyShapeStyle(.secondary))
        }
        .padding(16)
    }
}

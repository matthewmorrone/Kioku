import SwiftUI

// Renders the lyrics Live Activity's Lock Screen banner on the system's default activity
// background, everything centred. Layout: a header (playing indicator, note title), the current
// line with furigana and the next line beneath it (LyricsLineView), the progress row, then the
// transport buttons.
struct LyricsLiveActivityView: View {
    let title: String
    let state: LyricsActivityState

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                LyricsPlayingIndicator(isPlaying: state.isPlaying)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            LyricsLineView(state: state, baseSize: 21, rubySize: 10,
                           baseColor: AnyShapeStyle(.primary),
                           rubyColor: AnyShapeStyle(.secondary))
            LyricsActivityProgress(state: state)
            LyricsActivityControls(isPlaying: state.isPlaying)
        }
        .padding(16)
    }
}

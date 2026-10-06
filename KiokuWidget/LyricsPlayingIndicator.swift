import SwiftUI

// The waveform shown beside the note title while the song plays, a pause glyph while it's paused.
// Still: iOS doesn't run symbol effects or other continuous animation in a Live Activity.
struct LyricsPlayingIndicator: View {
    let isPlaying: Bool

    var body: some View {
        if isPlaying {
            Image(systemName: "waveform")
                .foregroundStyle(WidgetTheme.vermilion)
        } else {
            Image(systemName: "pause.fill")
                .foregroundStyle(WidgetTheme.vermilion)
        }
    }
}
